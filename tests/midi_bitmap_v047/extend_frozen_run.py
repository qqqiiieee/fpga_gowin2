"""Run another complete seed on an existing immutable compiled snapshot, then merge evidence."""
from pathlib import Path
import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BIN=Path('D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
NAMES=['src/midi_keyboard.v','src/midi_uart_rx.v','tests/midi_bitmap_v047/midi_keyboard_before.v',
       'tests/midi_bitmap_v047/tb_midi_bitmap_diff.sv','tests/midi_bitmap_v047/run_diff.py']
EXPECTED='0a51924531c4c981398d5ab98182a31da8c668ccdf5ec8311b73cf604de22969'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def merge(out):
    path=out/'results.json'
    if not path.exists():
        print('PRIMARY_SEED_STILL_RUNNING; additional seed retained for later --merge-only',flush=True)
        return
    report=json.loads(path.read_text())
    assert report['final_frozen_comparison'] and report['source_sha256_before']['src/midi_keyboard.v']==EXPECTED
    extra_files=sorted(out.glob('additional_seed_*.json'))
    existing_seeds={r['seed'] for r in report['runs']}
    for file in extra_files:
        r=json.loads(file.read_text())
        assert r['source_sha256_before']==report['source_sha256_before'], 'Different snapshot inputs'
        if r['seed'] not in existing_seeds:
            report['runs'].append(r);existing_seeds.add(r['seed'])
    report['all_snapshotted_inputs_unchanged']=all(sha(ROOT/n)==h for n,h in report['source_sha256_before'].items())
    report['source_sha256_after']={n:sha(ROOT/n) for n in NAMES}
    report['passed']=report['compile']['returncode']==0 and report['all_snapshotted_inputs_unchanged'] and all(r['passed'] for r in report['runs'])
    report['two_seed_packaging_requirement_met']=report['passed'] and len(existing_seeds)>=2
    report['compiled_simulation_sha256']=sha(out/'test.vvp')
    report['seed_extension_runner_sha256']=sha(Path(__file__))
    report['seed_extension_runner_snapshot']=str(out/'extend_frozen_run.py')
    text=json.dumps(report,indent=2)
    path.write_text(text,encoding='utf-8');(HERE/'final_latest.json').write_text(text,encoding='utf-8')
    lines=['V047 CE/SOP frozen differential regression', '',f'Passed: {report["passed"]}',
        f'Two distinct complete seeds: {report["two_seed_packaging_requirement_met"]}',
        f'Current SHA256: {EXPECTED}',f'Baseline SHA256: {report["source_sha256_before"][NAMES[2]]}',
        f'All source/test snapshot hashes unchanged: {report["all_snapshotted_inputs_unchanged"]}',
        'All 33 outputs compared pre-edge and post-NBA with X rejection; no invalid-field masking.',
        'Actual UART 31250baud, 1MHz clock/32 clocks per bit, original mapper idle guard320 clocks.',
        'MAPPING_ENABLE=1; disabled and identity-enabled full phases plus shifted-bank raw-note case.',
        'Active Sensing20ms accelerated; production27MHz/350ms and hardware are not certified here.',
        'No Gowin compilation, flashing or network was performed by this worker.',
        'Earlier150-second TIMEOUT and selfcheck ordering failure are retained separately, not passes.', '',
        *[f'Seed {r["seed"]}: passed={r["passed"]}, metrics={r["metrics"]}, log={r["log"]}' for r in report['runs']],
        '',f'Full result: {path}']
    for p in (out/'report.txt',HERE/'REPORT.txt'):p.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('MERGED_RESULTS '+str(path),flush=True)
    print('TWO_SEED_PASS '+str(report['two_seed_packaging_requirement_met']),flush=True)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-dir',required=True);p.add_argument('--seed',type=int,default=203047);p.add_argument('--merge-only',action='store_true')
    a=p.parse_args();out=Path(a.run_dir).resolve();assert out.is_relative_to(HERE/'results')
    if a.merge_only:merge(out);return
    before={n:sha(ROOT/n) for n in NAMES}
    assert before['src/midi_keyboard.v']==EXPECTED
    assert before=={n:sha(out/'snapshot'/n) for n in NAMES},'Snapshot/current inputs differ'
    assert (out/'test.vvp').is_file()
    compiled_sha=sha(out/'test.vvp');tool_sha=sha(BIN/'vvp.exe')
    (out/'extend_frozen_run.py').write_bytes(Path(__file__).read_bytes())
    log_path=out/f'run_seed_{a.seed}.log'
    cmd=[str(BIN/'vvp.exe'),'-i',str(out/'test.vvp'),f'+SEED={a.seed}']
    print('RUNNING '+str(log_path)+' timeout=600 seconds',flush=True)
    start=time.monotonic()
    with log_path.open('w',encoding='utf-8') as log_file:
        try:proc=subprocess.run(cmd,cwd=out,stdout=log_file,stderr=subprocess.STDOUT,timeout=600);code=proc.returncode
        except subprocess.TimeoutExpired:code=-1;log_file.write('\nTIMEOUT600\n')
    log=log_path.read_text(encoding='utf-8',errors='replace')
    match=re.search(r'BITMAP_DIFF_PASS (.+)',log)
    after={n:sha(ROOT/n) for n in NAMES}
    stable=before==after and sha(out/'test.vvp')==compiled_sha and sha(BIN/'vvp.exe')==tool_sha
    result=dict(seed=a.seed,command=cmd,returncode=code,seconds=round(time.monotonic()-start,3),timeout_seconds=600,
        log=str(log_path),metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',match[1])} if match else {},
        case_passes=re.findall(r'CASE_PASS (.+)',log),
        output_changes={k:int(v) for k,v in re.findall(r'OUTPUT_COVERAGE name=(\w+) changes=(\d+)',log)},
        passed=code==0 and match is not None and stable,negative_control_detected=False,
        source_sha256_before=before,source_sha256_after=after,all_snapshotted_inputs_unchanged=stable,
        compiled_simulation_sha256=compiled_sha,tool_sha256=tool_sha)
    (out/f'additional_seed_{a.seed}.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(log[-6500:],flush=True);merge(out)
    if not result['passed']:sys.exit(1)

if __name__=='__main__':main()
