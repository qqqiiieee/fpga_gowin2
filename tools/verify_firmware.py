"""Read the existing FPGA UserCode only; this tool cannot program SRAM or Flash."""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import argparse
import os
import hashlib
import json
import re
import subprocess

PROGRAMMER = Path(os.environ.get('GOWIN_HOME','D:/Gowin_V1.9.12.04_x64_win/Gowin/Gowin_V1.9.12.04_x64'))/'Programmer/bin/programmer_cli.exe'

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--programmer-cli', type=Path, default=PROGRAMMER)
    parser.add_argument('--cable-index', type=int, choices=range(6), default=int(os.environ.get('GOWIN_CABLE_INDEX', '4')),
                        help='installed CLI: 4=USB Debugger A; 1=FT2CH')
    parser.add_argument('--location', type=int, default=int(os.environ['GOWIN_USB_LOCATION']) if 'GOWIN_USB_LOCATION' in os.environ else None,
                        help='optional explicit USB location; no historical location is assumed')
    args = parser.parse_args(argv)
    if args.output.exists() or not args.output.parent.is_dir():
        parser.error('output must be a new file in an existing directory')
    manifest = json.loads(args.manifest.read_text(encoding='utf-8'))
    firmware = args.manifest.parent / manifest['firmware_name']
    actual_hash = hashlib.sha256(firmware.read_bytes()).hexdigest()
    if actual_hash != manifest['sha256']:
        raise RuntimeError('firmware hash does not match the release manifest')
    # operation 73 is READ UserCode, verified against the installed CLI help.
    # Board programming/erasure is intentionally absent from this command.
    command = [str(args.programmer_cli), '--device', 'GW2A-18C', '--run', '73',
               '--cable-index', str(args.cable_index), '--frequency', '0.5MHz']
    if args.location is not None:
        command += ['--location', str(args.location)]
    report = {'read_only': True, 'command': command, 'cable_index': args.cable_index, 'location': args.location, 'expected_usercode': manifest['usercode'],
              'firmware_sha256_verified': True,
              'checked_local': datetime.now(timezone(timedelta(hours=8))).isoformat(),
              'verified': False}
    try:
        result = subprocess.run(command, cwd=args.programmer_cli.parent, capture_output=True, timeout=15)
        text = (result.stdout+result.stderr).decode('utf-8', errors='replace')
        match = re.search(r'User Code is:\s*(0x[0-9a-fA-F]{8})', text)
        report.update(exit_code=result.returncode, log=text,
                      actual_usercode=match.group(1) if match else None)
        report['verified'] = bool(result.returncode == 0 and match
            and match.group(1).lower() == manifest['usercode'].lower()
            and 'cable open failed' not in text.lower() and '0xffffffff' not in text.lower())
    except (OSError, subprocess.TimeoutExpired) as exc:
        report['error'] = str(exc)
    with args.output.open('x', encoding='utf-8') as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
    print(json.dumps({'verified': report['verified'], 'actual_usercode': report.get('actual_usercode'),
                      'expected_usercode': report['expected_usercode'], 'record': str(args.output)}, ensure_ascii=True))
    return 0 if report['verified'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
