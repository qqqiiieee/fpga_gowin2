"""Offline five-group V039 USB diagnostic regression; no installs or devices."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = ROOT/'tests/phone_bridge/build'/('v039_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ'))
    out.mkdir(parents=True)
    def inputs():
        return {p.relative_to(ROOT).as_posix(): sha(p)
                for base in ('esp32_phone', 'tests/phone_bridge') for p in (ROOT/base).rglob('*')
                if p.is_file() and not any(part in ('build', '.build_work', '__pycache__', '.toolchain', 'node_modules') for part in p.parts)}
    before = inputs()
    report = dict(passed=False, source_sha256=before, checks=[], hardware_access=False,
                  hardware_uploaded=False, dependencies_installed=False)
    node = shutil.which('node')
    assert node, 'Use the installed Node runtime; no dependency installation allowed'
    jobs = [('native_old', ['cmd', '/c', 'tests\\phone_bridge\\run_native.cmd']),
            ('native_telemetry_api', ['cmd', '/c', 'tests\\phone_bridge\\run_telemetry.cmd']),
            ('ui_old', [node, 'tests/phone_bridge/web_ui.test.cjs']),
            ('ui_telemetry', [node, 'tests/phone_bridge/telemetry_ui.test.cjs']),
            ('usb_diagnostic', ['cmd', '/c', 'tests\\phone_bridge\\run_usb.cmd'])]
    try:
        for name, command in jobs:
            with (out/(name+'.log')).open('wb') as log:
                process = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120)
            report['checks'].append(dict(name=name, passed=process.returncode==0, exit_code=process.returncode))
            print(name, 'PASS' if process.returncode==0 else 'FAIL', flush=True)
            assert process.returncode == 0, (out/(name+'.log')).read_text(encoding='utf-8', errors='replace')[-5000:]
        assert before == inputs(), 'Sources changed during regression'
        baseline = json.loads((ROOT/'tests/phone_bridge/build/v039_canonical_before.json').read_text())
        canonical = Path(baseline['canonical_root'])
        report['canonical_source_sha256'] = {name: sha(canonical/'esp32_phone'/name) for name in baseline['canonical_source_sha256']}
        report['canonical_unchanged'] = report['canonical_source_sha256'] == baseline['canonical_source_sha256']
        report['protocol_core_unchanged'] = sha(ROOT/'esp32_phone/bridge_core.h') == baseline['isolated_before_source_sha256']['bridge_core.h']
        report['web_ui_unchanged'] = sha(ROOT/'esp32_phone/web_ui.h') == baseline['isolated_before_source_sha256']['web_ui.h']
        assert report['canonical_unchanged'] and report['protocol_core_unchanged'] and report['web_ui_unchanged']
        report['passed'] = True
    except Exception as exc:
        report['error'] = repr(exc)
        raise
    finally:
        (out/'results.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
        print('REPORT', out/'results.json', flush=True)


if __name__ == '__main__':
    main()
