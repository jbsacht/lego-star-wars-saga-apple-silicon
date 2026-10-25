#!/usr/bin/env python3
"""Build a private compatibility app from the user's original Mac App Store game."""
import argparse
import datetime
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SUPPORTED_SHA256 = 'a39bf58792b14509ff9c14e625f7adad98b186273903e680d2e1aeb014197b4c'
PREFERENCES = Path.home() / 'Library/Application Support/Feral Interactive/LEGO Star Wars Saga/Preferences Data'


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def validate_source(source):
    info_path = source / 'Contents/Info.plist'
    if not info_path.is_file():
        raise ValueError('Choose the original installed .app, not a shortcut or a compatibility app.')
    info = plistlib.loads(info_path.read_bytes())
    if not isinstance(info, dict):
        raise ValueError('The original app has an invalid Info.plist.')
    required = {'CFBundleIdentifier': 'com.feralinteractive.Saga',
                'CFBundleShortVersionString': '1.1.1', 'FeralVersionSuffix': 'RC4',
                'FeralVersionType': '2'}
    if any(str(info.get(key)) != value for key, value in required.items()):
        raise ValueError('This setup supports only the Mac App Store 1.1.1 RC4 release. '
                         'Steam, DVD and other revisions require separate validation.')
    if info.get('CFBundleExecutable') != 'LEGO Star Wars Saga':
        raise ValueError('The original app has an unexpected executable name.')
    executable = source / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.is_file() or hashlib.sha256(executable.read_bytes()).hexdigest() != SUPPORTED_SHA256:
        raise ValueError('The original executable does not match the tested release; no files were changed.')
    for relative in ['Resources/SagaData.dmg', 'Resources/Saga.icns', '_MASReceipt/receipt']:
        path = source / 'Contents' / relative
        if not path.is_file() or not path.stat().st_size:
            raise ValueError('The installed game is incomplete: missing ' + relative)
    return info, executable


def configure_display(path):
    """Back up preferences and change only the legacy fullscreen setting."""
    if path.exists():
        tree = ET.parse(path)  # Reject malformed preferences instead of overwriting them.
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        backup = path.with_name(path.name + '.before-apple-silicon-' + stamp)
        shutil.copy2(path, backup)
        print('Preferences backup:', backup)
    else:
        tree = ET.ElementTree(ET.Element('registry'))
    parent = tree.getroot()
    for name in ['HKEY_CURRENT_USER', 'Software', 'Feral Interactive', 'LEGO Star Wars Saga', 'Setup']:
        child = next((node for node in parent.findall('key') if node.get('name') == name), None)
        if child is None:
            child = ET.SubElement(parent, 'key', name=name)
        parent = child
    value = next((node for node in parent.findall('value') if node.get('name') == 'FullScreen'), None)
    if value is None:
        value = ET.SubElement(parent, 'value', name='FullScreen', type='integer')
    value.set('type', 'integer')
    value.text = '0'
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.apple-silicon.tmp')
    try:
        tree.write(temporary, encoding='UTF-8', xml_declaration=True)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def build(source, output, set_display=False):
    info, executable = validate_source(source)
    if output.exists():
        raise ValueError('Output already exists. Choose a new --output path; existing apps are never replaced.')
    if source == output or source in output.parents:
        raise ValueError('The output must be outside the original app.')
    if platform.system() != 'Darwin':
        raise ValueError('Building requires macOS, Xcode command-line tools and Rosetta 2 on Apple Silicon.')
    run('xcrun', '--find', 'clang')
    run('xcrun', '--find', 'clang++')
    run('arch', '-x86_64', '/usr/bin/true')
    if set_display and subprocess.run(['pgrep', '-x', 'LEGOCompleteSagaCompat'],
                                    stdout=subprocess.DEVNULL).returncode == 0:
        raise ValueError('Quit the compatibility game before changing its display preference.')
    native = ROOT / 'native'
    run('make', '-C', native, 'build/game_loader')
    loader = native / 'build/game_loader'
    # Exercise the same native signature validation used by the delayed game check.
    env = dict(os.environ, LP32_SECURITY_SELFTEST=str(source), LP32_NO_DIAGNOSTIC_LOG='1',
               LP32_MUTE_AUDIO='1', LP32_BACKGROUND_TEST='1')
    run('arch', '-x86_64', loader, executable, env=env)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.saga-build-', dir=output.parent) as directory:
        app = Path(directory) / 'LEGOCompleteSaga-Compat.app'
        contents = app / 'Contents'
        for relative in ['MacOS', 'Resources', 'SharedSupport', 'Library/Frameworks']:
            (contents / relative).mkdir(parents=True, exist_ok=True)
        run('ditto', '--noqtn', source / 'Contents/Resources', contents / 'Resources')
        run('ditto', '--noqtn', source / 'Contents/_MASReceipt', contents / '_MASReceipt')
        shutil.copy2(loader, contents / 'MacOS/LEGOCompleteSagaCompat')
        image = contents / 'SharedSupport/LEGOCompleteSaga.image'
        shutil.copy2(executable, image)
        image.chmod(0o644)
        # Preserve the publisher's edition/receipt metadata and use the original
        # signed installation as the guest code identity. No requirement is bypassed.
        info.update(CFBundleExecutable='LEGOCompleteSagaCompat',
                    CFBundleIdentifier='com.feralinteractive.Saga.compat',
                    CFBundleName='LEGO Complete Saga (Compatibility)',
                    CFBundleIconFile='Saga.icns', NSPrincipalClass='NSApplication',
                    NSHighResolutionCapable=False, LSMinimumSystemVersion='11.0',
                    LP32ContinueWhenInactive=False, LP32GuestCodeBundlePath=str(source))
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        shutil.copy2(ROOT / 'README.md', contents / 'SharedSupport/Compatibility-README.md')
        run(sys.executable, native / 'tools/flatten_resource_forks.py', app)
        run('codesign', '--force', '--deep', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        if set_display:
            configure_display(PREFERENCES)
        if output.exists():
            raise ValueError('Output was created during the build; refusing to replace it.')
        app.rename(output)
    print('\nBuilt:', output)
    print('Keep the original installed game at:', source)
    print('Open the new app, click Play, then press Enter. Use Control–Command–F for fullscreen.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('/Applications/LEGO Star Wars Saga.app'))
    parser.add_argument('--output', type=Path, default=ROOT / 'build/LEGO Star Wars Saga (Apple Silicon).app')
    parser.add_argument('--check', action='store_true', help='Check the installed edition without building or changing anything')
    parser.add_argument('--configure-display', action='store_true',
                        help='Back up preferences and disable legacy fullscreen; use macOS fullscreen instead')
    args = parser.parse_args()
    source, output = args.source.expanduser().resolve(), args.output.expanduser().resolve()
    try:
        if args.check:
            validate_source(source)
            print('Supported original Mac App Store 1.1.1 RC4 installation found. No files changed.')
        else:
            build(source, output, args.configure_display)
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError, plistlib.InvalidFileException) as error:
        print('Setup stopped:', error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
