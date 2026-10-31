"""Independent chord RTL verification; writes only tests/chords_v047.

No production edits, synthesis, firmware build, programming or serial access.
"""
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TOOLS = Path('D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
CASES = {
    'modes': ['guide_chord_modes.v'],
    'events': ['guide_chord_events.v', 'voice_allocator.v'],
    'score_pixels': ['phone_extension_state.v', 'piano_roll_guide.v',
                     'piano_roll_renderer.v', 'custom_score_ram.v', 'piano_roll_score.v'],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = HERE / 'results' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    snap = out / 'snapshot'
    names = sorted({'src/' + f for files in CASES.values() for f in files} | {'src/piano_layout.vh'})
    names += ['tests/chords_v047/tb_' + name + '.v' for name in CASES]
    names += ['tests/chords_v047/run_tests.py']
    hashes = {}
    for name in names:
        data = (ROOT / name).read_bytes()
        p = snap / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    report = dict(status='running', run_directory=str(out), source_sha256=hashes,
                  tools={str(TOOLS / n): sha(TOOLS / n) for n in ['iverilog.exe', 'vvp.exe']},
                  checks=[], production_modified_by_runner=False, hardware_accessed=False,
                  full_project_built=False, synthesized=False, flashed=False)

    def execute(argv):
        try:
            p = subprocess.run(list(map(str, argv)), cwd=snap, capture_output=True,
                               encoding='utf-8', errors='replace', timeout=60)
            return dict(argv=list(map(str, argv)), returncode=p.returncode, stdout=p.stdout, stderr=p.stderr)
        except subprocess.TimeoutExpired as exc:
            return dict(argv=list(map(str, argv)), returncode=None, error=str(exc))

    def case(name, sources):
        top = 'tb_' + name
        binary = out / (name + '.vvp')
        compiled = execute([TOOLS / 'iverilog.exe', '-g2012', '-Wall', '-s', top, '-o', binary,
                            *['src/' + f for f in sources], 'tests/chords_v047/' + top + '.v'])
        run = execute([TOOLS / 'vvp.exe', binary]) if compiled['returncode'] == 0 else None
        passed = bool(run and run['returncode'] == 0 and '_PASS' in run['stdout'])
        result = dict(name=name, passed=passed, compile=compiled, run=run)
        (out / (name + '.json')).write_text(json.dumps(result, indent=2), encoding='utf-8')
        return result

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(case, name, sources) for name, sources in CASES.items()]
        for future in as_completed(futures):
            result = future.result()
            report['checks'].append(result)
            print(result['name'], 'PASS' if result['passed'] else 'FAIL',
                  (result['run'] or result['compile']).get('stdout', ''), flush=True)
    report['changed_inputs_during_run'] = [n for n in names if sha(ROOT / n) != hashes[n]]
    report['status'] = 'pass' if all(c['passed'] for c in report['checks']) and not report['changed_inputs_during_run'] else 'fail'
    text = json.dumps(report, indent=2)
    (out / 'report.json').write_text(text, encoding='utf-8')
    (HERE / 'latest_report.json').write_text(text, encoding='utf-8')
    print(report['status'].upper(), out, flush=True)
    return 0 if report['status'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
