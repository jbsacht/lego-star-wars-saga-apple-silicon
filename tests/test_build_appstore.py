import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('builder', Path(__file__).resolve().parents[1] / 'tools/build_appstore.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class SourceValidation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name) / 'Original Game.app'
        self.contents = self.source / 'Contents'
        self.info = dict(CFBundleIdentifier='com.feralinteractive.Saga',
                         CFBundleShortVersionString='1.1.1', FeralVersionSuffix='RC4',
                         FeralVersionType='2', CFBundleExecutable='LEGO Star Wars Saga')
        self.contents.mkdir(parents=True)
        self.write_info()
        self.payload = b'unit-test fixture, not game code'
        for relative, data in [('MacOS/LEGO Star Wars Saga', self.payload),
                               ('Resources/SagaData.dmg', b'fixture'),
                               ('Resources/Saga.icns', b'fixture'),
                               ('_MASReceipt/receipt', b'fixture')]:
            path = self.contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.hash_patch = mock.patch.object(builder, 'SUPPORTED_SHA256', hashlib.sha256(self.payload).hexdigest())
        self.hash_patch.start()
        self.addCleanup(self.hash_patch.stop)

    def write_info(self):
        (self.contents / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def test_matching_installed_edition_is_accepted(self):
        info, executable = builder.validate_source(self.source)
        self.assertEqual(info, self.info)
        self.assertEqual(executable.read_bytes(), self.payload)

    def test_steam_or_retail_edition_is_rejected(self):
        self.info['FeralVersionType'] = '1'
        self.write_info()
        with self.assertRaisesRegex(ValueError, 'Mac App Store'):
            builder.validate_source(self.source)

    def test_modified_game_binary_is_rejected(self):
        (self.contents / 'MacOS/LEGO Star Wars Saga').write_bytes(self.payload + b'changed')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            builder.validate_source(self.source)

    def test_missing_receipt_is_rejected(self):
        (self.contents / '_MASReceipt/receipt').unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            builder.validate_source(self.source)

    def test_unexpected_executable_path_is_rejected(self):
        self.info['CFBundleExecutable'] = '../../other-file'
        self.write_info()
        with self.assertRaisesRegex(ValueError, 'unexpected executable'):
            builder.validate_source(self.source)


class PreferenceSafety(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'Preferences Data'

    def test_existing_settings_are_backed_up_and_preserved(self):
        original = b'''<registry><key name="HKEY_CURRENT_USER"><key name="Software"><key name="Feral Interactive"><key name="LEGO Star Wars Saga"><key name="Setup"><value name="FullScreen" type="integer">1</value><value name="ScreenW" type="integer">1280</value></key><key name="Config"><value name="MasterVolume" type="integer">7</value></key></key></key></key></key></registry>'''
        self.path.write_bytes(original)
        builder.configure_display(self.path)
        backups = list(self.path.parent.glob('Preferences Data.before-apple-silicon-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        values = {node.get('name'): node.text for node in ET.parse(self.path).iter('value')}
        self.assertEqual(values, {'FullScreen': '0', 'ScreenW': '1280', 'MasterVolume': '7'})

    def test_first_run_creates_only_the_required_setting(self):
        builder.configure_display(self.path)
        values = list(ET.parse(self.path).iter('value'))
        self.assertEqual(len(values), 1)
        self.assertEqual((values[0].get('name'), values[0].text), ('FullScreen', '0'))

    def test_corrupted_preferences_are_not_overwritten(self):
        original = b'<registry>broken'
        self.path.write_bytes(original)
        with self.assertRaises(ET.ParseError):
            builder.configure_display(self.path)
        self.assertEqual(self.path.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
