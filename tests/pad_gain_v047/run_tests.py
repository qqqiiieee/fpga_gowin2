"""Local Icarus simulation only; all generated files stay in this directory.

python tests/pad_gain_v047/run_tests.py [--tools PATH]
No synthesis, full-project build, firmware generation, flash, ESP writes or publish.
"""
from pathlib import Path
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse
import csv
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
INPUTS = ['src/performance_mixer.v', 'src/drum_voice.v', 'src/snare_voice.v',
          'src/hat_voice.v', 'src/audio_effects.v', 'src/instrument_audio.v',
          'src/midi_keyboard.v', 'src/midi_control_bank.v',
          *['tests/pad_gain_v047/' + p for p in ('performance_mixer_before.v',
              'tb_boundaries.v', 'tb_waveforms.v', 'tb_fx.v', 'run_tests.py')]]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def code(text):
    return re.sub(r'\s+', '', re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, default=Path(
        'D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin'))
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out = HERE / 'results' / stamp
    snap = out / 'snapshot'
    snap.mkdir(parents=True)
    before = {name: sha(ROOT / name) for name in INPUTS}
    for name in INPUTS:
        target = snap / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    baseline = (snap / 'tests/pad_gain_v047/performance_mixer_before.v').read_text(encoding='utf-8-sig')
    current = (snap / 'src/performance_mixer.v').read_text(encoding='utf-8-sig')
    minimal = code(current) == code(baseline.replace('drums_sum>>>2', 'drums_sum>>>1'))
    assert minimal, 'Unexpected functional change beyond the one-bit fixed shift'
    reference = snap / 'performance_mixer_before.v'
    reference.write_text(baseline.replace('module performance_mixer(', 'module performance_mixer_before('), encoding='utf-8')
    iv, vvp = args.tools / 'iverilog.exe', args.tools / 'vvp.exe'
    report = dict(status='running', utc=stamp, run_directory=str(out),
                  input_sha256=before, shift_only_logic_change=minimal,
                  rtl_multiplier_count_before=code(baseline).count('*'),
                  rtl_multiplier_count_after=code(current).count('*'),
                  tools={str(p): sha(p) for p in (iv, vvp)}, checks=[],
                  full_project_built=False, synthesized=False, hardware_tested=False,
                  firmware_generated=False, flashed=False, published=False)

    def execute(argv, cwd):
        start = time.monotonic()
        p = subprocess.run([str(x) for x in argv], cwd=cwd, capture_output=True,
                           text=True, encoding='utf-8', errors='replace', timeout=240)
        return dict(argv=[str(x) for x in argv], returncode=p.returncode,
                    seconds=round(time.monotonic()-start, 3), stdout=p.stdout, stderr=p.stderr)

    def case(name, top, sources, parameters=(), plusargs=()):
        work = out / name
        work.mkdir()
        binary = work / 'test.vvp'
        bench = snap / ('tests/pad_gain_v047/' + top + '.v')
        compiled = execute([iv, '-g2012', '-Wall', '-s', top, *parameters, '-o', binary,
                            bench, snap / 'src/performance_mixer.v', reference,
                            *[snap / p for p in sources]], work)
        run = execute([vvp, binary, *plusargs], work) if compiled['returncode'] == 0 else None
        passed = bool(run and run['returncode'] == 0 and '_PASS' in run['stdout']
                      and not re.search(r'(?m)^(FATAL|ERROR):', run['stdout'] + run['stderr']))
        item = dict(name=name, passed=passed, compile=compiled, run=run)
        (work / 'commands.json').write_text(json.dumps(item, indent=2), encoding='utf-8')
        return item

    drums = ['src/drum_voice.v', 'src/snare_voice.v', 'src/hat_voice.v']
    jobs = [('boundaries', 'tb_boundaries', []),
            ('waveforms', 'tb_waveforms', drums),
            ('cadence8', 'tb_waveforms', drums, [], ['+frames=2048', '+quick=1']),
            ('cadence288', 'tb_waveforms', drums, ['-Ptb_waveforms.PERIOD=288'], ['+frames=2048', '+quick=1']),
            ('fx', 'tb_fx', ['src/audio_effects.v'])]
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = {pool.submit(case, *job): job[0] for job in jobs}
            for future in as_completed(futures):
                result = future.result()
                report['checks'].append(result)
                print(result['name'], 'PASS' if result['passed'] else 'FAIL',
                      (result['run'] or result['compile'])['stdout'].strip(), flush=True)
        report['cadence_trace_identical'] = (
            (out / 'cadence8/wave_trace.csv').read_bytes() == (out / 'cadence288/wave_trace.csv').read_bytes())
        report['cadence_metrics_identical'] = (
            (out / 'cadence8/wave_metrics.csv').read_bytes() == (out / 'cadence288/wave_metrics.csv').read_bytes())
        with (out / 'waveforms/wave_metrics.csv').open() as stream:
            rows = [{k: int(v) for k, v in row.items()} for row in csv.DictReader(stream)]
        for row in rows:
            row['old_rms'] = round(math.sqrt(row['old_energy']/row['samples']), 4)
            row['new_rms'] = round(math.sqrt(row['new_energy']/row['samples']), 4)
            row['gain_db'] = round(10*math.log10(row['new_energy']/row['old_energy']), 5) if row['old_energy'] else None
        report['measurements'] = rows
        report['velocity_monotonic'] = all(
            all(a < b for a, b in zip(values, values[1:]))
            for balance in (128, 255) for lane in range(5)
            for values in [[r['new_energy'] for r in rows if r['scenario'] == 0
                            and r['balance'] == balance and r['lane'] == lane]])
        report['inputs_stable_during_tests'] = before == {name: sha(ROOT / name) for name in INPUTS}
        originals = json.loads((HERE / 'src_before.json').read_text(encoding='utf-8-sig'))
        report['src_changed_since_task_start'] = [r['path'] for r in originals if sha(ROOT / r['path']) != r['sha256']]
        report['status'] = 'pass' if (all(c['passed'] for c in report['checks'])
            and report['cadence_trace_identical'] and report['cadence_metrics_identical']
            and report['velocity_monotonic'] and report['inputs_stable_during_tests']) else 'fail'
    except Exception as exc:
        report.update(status='fail', error=repr(exc))
    (out / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    (HERE / 'latest_report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(report['status'].upper(), out, flush=True)
    return 0 if report['status'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
