"""Forward an explicit UTF-8 device JSON config to oscillator_test.main.

This stdlib-only launcher never enumerates or chooses devices. Plan mode
reads only the supplied config and forwards --plan-only to the main tool.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

import oscillator_test


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate config field: '+key)
        result[key] = value
    return result


def load_config(path):
    # Also accept a UTF-8 BOM produced by Windows editors/PowerShell.
    config = json.loads(Path(path).read_text(encoding='utf-8-sig'), object_pairs_hook=unique_object)
    if not isinstance(config, dict) or set(config) != {'port', 'device_id', 'device_name'}:
        raise ValueError('config must contain exactly port, device_id and device_name')
    port, device_id, name = config['port'], config['device_id'], config['device_name']
    if not isinstance(port, str) or not re.fullmatch(r'COM[1-9][0-9]*', port, re.IGNORECASE):
        raise ValueError('config port must be an explicit COMn')
    if type(device_id) is not int or not 0 <= device_id < 0xffffffff:
        raise ValueError('config device_id must be a nonnegative integer input ID; no default-device sentinel')
    if not isinstance(name, str) or 'USB-Audio' not in name or any(c in name for c in '\x00\r\n'):
        raise ValueError('config device_name must be the exact USB-Audio input name')
    # Preserve the complete name as supplied: no trimming or name fallback.
    return dict(port=port.upper(), device_id=device_id, device_name=name)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='explicit UTF-8 JSON device config')
    parser.add_argument('--manifest', type=Path, required=True, help='explicit release manifest path')
    parser.add_argument('--output-dir', type=Path, required=True, help='explicit output directory')
    parser.add_argument('--plan-only', action='store_true')
    parser.add_argument('--independence', action='store_true')
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
    except (OSError, UnicodeError, ValueError) as exc:
        parser.error('invalid device config: '+str(exc))
    forwarded = ['--port', config['port'], '--device-id', str(config['device_id']),
                 '--device-name', config['device_name'], '--manifest', str(args.manifest),
                 '--output-dir', str(args.output_dir)]
    if args.plan_only:
        forwarded.append('--plan-only')
    if args.independence:
        forwarded.append('--independence')
    return oscillator_test.main(forwarded)


if __name__ == '__main__':
    raise SystemExit(main())
