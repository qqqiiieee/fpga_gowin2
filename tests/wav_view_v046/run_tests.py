"""Offline native x64/x86 tests only. Never opens hardware or builds firmware."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import subprocess
import sys

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
VC = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    names = ['esp32_phone/wav_view.h', 'esp32_phone/v041_core.h',
             'esp32_phone/bridge_core.h', 'tests/wav_view_v046/native.cpp',
             'tests/wav_view_v046/run_tests.py']
    before = {name: sha(ROOT / name) for name in names}
    production_before = {str(p.relative_to(ROOT)).replace('\\', '/'): sha(p)
                         for p in sorted((ROOT / 'src').rglob('*')) if p.is_file()}
    checks = []
    for arch, setup in [('x64', 'vcvars64.bat'), ('x86', 'vcvars32.bat')]:
        build = OUT / arch
        build.mkdir(exist_ok=True)
        batch = build / 'run.cmd'
        batch.write_text('\n'.join([
            '@echo off', 'setlocal', 'set VSCMD_SKIP_SENDTELEMETRY=1',
            f'set "TEMP={build}"', f'set "TMP={build}"',
            f'call "{VC / setup}" >nul', 'if errorlevel 1 exit /b 1',
            f'cl /nologo /utf-8 /std:c++14 /EHsc /W4 /Od /RTC1 /Fe:"{build / "native.exe"}" /Fo:"{build / "native.obj"}" "{OUT / "native.cpp"}"',
            'if errorlevel 1 exit /b 1', f'"{build / "native.exe"}"',
            'exit /b %errorlevel%', ''
        ]), encoding='utf-8')
        try:
            result = subprocess.run([os.environ.get('COMSPEC', 'cmd.exe'), '/d', '/c', str(batch)],
                                    cwd=build, capture_output=True, text=True,
                                    encoding='utf-8', errors='replace', timeout=60)
            log = result.stdout + result.stderr
            passed = result.returncode == 0 and 'WAV_VIEW_V046_PASS' in log
            code = result.returncode
        except (OSError, subprocess.TimeoutExpired) as error:
            log, passed, code = repr(error), False, None
        (build / 'native.log').write_text(log, encoding='utf-8')
        print(log, flush=True)
        checks.append(dict(architecture=arch, passed=passed, exit_code=code,
                           log=f'{arch}/native.log'))
    after = {name: sha(ROOT / name) for name in names}
    production_after = {str(p.relative_to(ROOT)).replace('\\', '/'): sha(p)
                        for p in sorted((ROOT / 'src').rglob('*')) if p.is_file()}
    stable = before == after
    unchanged = production_before == production_after
    report = dict(passed=all(c['passed'] for c in checks) and stable and unchanged,
                  utc=datetime.now(timezone.utc).isoformat(), checks=checks,
                  source_sha256={Path(name).name: value for name, value in after.items()},
                  source_paths=names, tested_sources_unchanged=stable,
                  production_src_unchanged=unchanged, production_src_sha256=production_after,
                  hardware_accessed=False, firmware_built=False,
                  scope='Native helper only; no runtime/HTTP integration, LittleFS target, flash or serial validation.')
    (OUT / 'results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
