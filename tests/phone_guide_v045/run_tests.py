"""Offline host C++ / embedded JS tests. All outputs stay in this directory.
Compiles native test executables only; never builds/flashes ESP32 or FPGA.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
sys.stdout.reconfigure(encoding='utf-8')

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
SOURCE = (ROOT / 'esp32_phone/v041_runtime.h').read_text(encoding='utf-8')


def function(source, name):
    match = re.search(r'(?:inline|static) [^\n{]+\b' + name + r'\([^\n]*?\)\s*\{', source)
    assert match, name
    start = match.start()
    pos = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[start:pos]


def digest(data):
    return hashlib.sha256(data).hexdigest()


baseline = json.loads((OUT / 'preservation_baseline.json').read_text())
concurrent_changes = []
for name, value in baseline['unchanged_files'].items():
    if digest((ROOT / name).read_bytes()) != value:
        # Other agents own e.g. the parent menu/tutorial. Do not overwrite them.
        assert Path(name).name not in ['recording_uart.h', 'v041_core.h', 'v041_json.h', 'bridge_core.h'], name
        concurrent_changes.append(name)
for name, value in baseline['recording_functions'].items():
    assert digest(function(SOURCE, name).encode()) == value, name
ino = (ROOT / 'esp32_phone/esp32_phone.ino').read_text(encoding='utf-8')
assert digest(re.sub(r'(FIRMWARE_VERSION\[\] = )"[^"]+"', r'\1"VERSION"', ino).encode()) == baseline['ino_except_version']
before = (OUT / 'runtime_before.txt').read_text(encoding='utf-8')
# Recording scheduler and ACK handling remain byte-for-byte equivalent.
for begin, end in [(' if(audio.active&&recordStarted', ' if(rpc.inflight)'),
                   (' else if(job.kind==3){', ' else if(job.kind==6)'),
                   (' else if(job.kind==8){', '\n}\ninline void scheduler')]:
    old = before[before.index(begin):before.index(end, before.index(begin))]
    assert old in SOURCE, begin
print('PRESERVATION_PASS: recording UART/core/JSON and recording functions unchanged; ino version only')

names = ['newJob', 'failJob', 'finishJob', 'issue', 'guideAck', 'consumeAck', 'scheduler', 'jobJson', 'guideJson', 'enqueueGuide']
guide = SOURCE[SOURCE.index('static const uint8_t GUIDE_MODE'):SOURCE.index('static SemaphoreHandle_t mutex;')]
job = re.search(r'struct Job \{[^\n]+\} job;', SOURCE)[0]
(OUT / 'runtime_under_test.inc').write_text(guide + '\n' + job + '\n' + '\n'.join(function(SOURCE, n) for n in names), encoding='utf-8')
json_source = (ROOT / 'esp32_phone/v041_json.h').read_text(encoding='utf-8')
(OUT / 'json_helpers_under_test.inc').write_text('namespace v041 {\n' + '\n'.join(function(json_source, n) for n in ['integer', 'item', 'keys']) + '\n}', encoding='utf-8')
(OUT / 'http_under_test.inc').write_text('\n'.join(function(SOURCE, n) for n in ['sendJson', 'bodyLimit', 'guideSubmit']), encoding='utf-8')

# Verify registration reaches the functions under test, with distinct legacy op20.
for route, body in [('control', 'guideSubmit(9)'), ('mode', 'guideSubmit(10)'), ('state', 'guideSubmit(11)')]:
    assert f'server.on("/api/guide/{route}",HTTP_POST,[](){{{body};}});' in SOURCE
assert 'server.on("/api/scores/control",HTTP_POST,[](){guideSubmit(6);});' in SOURCE
get = re.search(r'server.on\("/api/guide/state",HTTP_GET,[^\n]+', SOURCE)[0]
assert 'guideJson(millis())' in get and 'issue(' not in get and 'enqueueGuide' not in get

compiler_setup = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
assert compiler_setup.exists()
cmd = f'''@echo off
setlocal
set VSCMD_SKIP_SENDTELEMETRY=1
set "TEMP={OUT}"
set "TMP={OUT}"
call "{compiler_setup}" >nul
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /W4 /Fe:"{OUT / 'native.exe'}" /Fo:"{OUT / 'native.obj'}" "{OUT / 'native.cpp'}"
if errorlevel 1 exit /b 1
"{OUT / 'native.exe'}"
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /Fe:"{OUT / 'recording_regression.exe'}" /Fo:"{OUT / 'recording_regression.obj'}" "{ROOT / 'tests/v041_esp_native.cpp'}"
if errorlevel 1 exit /b 1
"{OUT / 'recording_regression.exe'}"
'''
(OUT / 'native.cmd').write_text(cmd, encoding='utf-8')
records = []
for name, args in [('native', ['cmd', '/d', '/c', str(OUT / 'native.cmd')]),
                   ('ui', ['node', str(OUT / 'ui.test.cjs')]),
                   ('legacy_ui', ['node', str(ROOT / 'tests/v041_esp_ui.cjs')])]:
    p = subprocess.run(args, cwd=OUT, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=60)
    log = p.stdout + p.stderr
    (OUT / f'{name}.log').write_text(log, encoding='utf-8')
    print(log)
    records.append({'name': name, 'passed': p.returncode == 0, 'exit_code': p.returncode})
report = {'passed': all(r['passed'] for r in records), 'checks': records,
          'preservation_passed': True, 'utc': datetime.now(timezone.utc).isoformat(),
          'concurrent_changes_outside_this_task': concurrent_changes,
          'scope': 'Actual runtime functions extracted verbatim; native UART/FPGA model and embedded JS VM DOM. No ESP32/FPGA firmware build, hardware, flash, or network validation.',
          'source_sha256': {n: digest((ROOT / 'esp32_phone' / n).read_bytes()) for n in ['v041_runtime.h', 'v041_ui.h', 'esp32_phone.ino']}}
(OUT / 'results.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
sys.exit(0 if report['passed'] else 1)
