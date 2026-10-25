#!/usr/bin/env python3
"""Reject game/private artifacts in files that could enter a public commit."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
INHERITED_ART = {'native/icons/LEGOCloneWars-art.png', 'native/icons/LEGOCloneWars.icns',
                 'native/icons/LEGOPirates-art.png', 'native/icons/LEGOPirates.icns'}
FORBIDDEN = {'.dmg', '.dat', '.image', '.log', '.ips', '.mov', '.m4v', '.mp3', '.ogg',
             '.zip', '.gz', '.png', '.jpg', '.jpeg', '.icns'}
EXECUTABLE_MAGIC = {b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
                    b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\x7fELF'}


def main():
    raw = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
    names = {item.decode() for item in raw.split(b'\0') if item}
    failures = []
    for name in sorted(names):
        path = Path(name)
        full = ROOT / path
        if not full.is_file():
            continue
        parts = [part.lower() for part in path.parts]
        lower = path.name.lower()
        if any(part.endswith('.app') or part in {'_masreceipt', 'savedgames'} for part in parts) or \
                lower == 'receipt' or lower.startswith('preferences data') or lower.endswith('_savedgame') or \
                (path.suffix.lower() in FORBIDDEN and name not in INHERITED_ART):
            failures.append(name)
            continue
        with full.open('rb') as stream:
            header = stream.read(4)
        if header in EXECUTABLE_MAGIC:
            failures.append(name)
    if failures:
        print('Do not publish these generated/private files:', file=sys.stderr)
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print(f'Public-tree check passed for {len(names)} files; only the four inherited upstream icons are allowed artwork.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
