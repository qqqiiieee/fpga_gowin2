"""Offline immutable-snapshot UART differential regression. Writes only beside this file."""
from pathlib import Path
import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BIN = Path('D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
REFERENCE_SHA = '08c12d1f527fdb8d2e74dd57df86b8e744931176d47f398d069ae6be84a2a58d'
OUTPUTS = '''event_valid event_on event_off event_note event_velocity held_notes
program_valid timbre_select volume_valid volume bend_valid bend modulation hit0 hit1
drum_velocity0 drum_velocity1 panic framing_error overflow received_count cc_valid
cc_number cc_value hat_closed_hit hat_open_hit hat_closed_velocity hat_open_velocity
mapping_wr_ready mapping_commit_ready mapping_commit_ack receipt_note_on receipt_note'''.split()

def digest(data):
    return hashlib.sha256(data).hexdigest()

def ports(source):
    source = re.sub(r'//[^\n]*|/\*.*?\*/', '', source, flags=re.S)
    header = source.split(')(', 1)[1].split(');', 1)[0]
    ans = []
    for match in re.finditer(r'\b(input|output)\s+(?:wire|reg)\s*(signed\s+)?(\[[^]]+\]\s*)?([^()]*?)(?=\binput\b|\boutput\b|$)', header):
        direction, signed, width, names = match.groups()
        for name in names.strip().rstrip(',').split(','):
            name = name.strip()
            assert re.fullmatch(r'\w+', name), name
            ans.append((direction, (signed or '') + (width or ''), name))
    assert [n for d, w, n in ans if d == 'output'] == OUTPUTS
    return ans

def generated_interface(interface):
    lines = ['// Generated from the preserved reference ANSI ports; no RTL behavior copied.']
    for prefix in ('b', 'c'):
        for direction, width, name in interface:
            if direction == 'output':
                lines.append(f'wire {width}{prefix}_{name};')
        module = 'midi_keyboard_before' if prefix == 'b' else 'midi_keyboard'
        lines.append(f'{module} #(.CLK_HZ(CLK_HZ), .ACTIVE_SENSE_MS(ACTIVE_SENSE_MS), .MAPPING_ENABLE(1)) {prefix} (')
        lines.append(',\n'.join(f'  .{name}({prefix + "_" if direction == "output" else ""}{name})' for direction, width, name in interface))
        lines.append(');')
    b_bundle = '{'+','.join('b_'+name for name in OUTPUTS)+'}'
    c_bundle = '{'+','.join('c_'+name for name in OUTPUTS)+'}'
    lines += ['integer comparisons=0;', 'task compare_outputs;', 'input [127:0] sample;', 'begin', 'comparisons=comparisons+1;', f'if ({b_bundle} !== {c_bundle}) begin']
    for name in OUTPUTS:
        lines += [f'if (b_{name} !== c_{name}) begin',
                  f'  $display("DIFF_FAIL phase=%0s cycle=%0d sample=%0s output={name} baseline=%h current=%h rx=%b ready=%b suppress=%b", phase, cycles, sample, b_{name}, c_{name}, rx, event_ready, suppress);',
                  '  $fatal(1,"cycle exact output mismatch"); end']
    lines += ['end', f'if ((^{b_bundle}) === 1\'bx) $fatal(1,"UNKNOWN_OUTPUT cycle=%0d phase=%0s",cycles,phase);', 'end', 'endtask']
    for name in OUTPUTS:
        width = next(w for d, w, n in interface if n == name)
        lines += [f'reg {width}previous_{name};', f'integer changes_{name}=0;']
    lines += [f'reg [$bits({b_bundle})-1:0] previous_bundle;', 'task track_changes; begin', f'if ({b_bundle} !== previous_bundle) begin']
    for name in OUTPUTS:
        lines += [f'if (b_{name} !== previous_{name}) changes_{name}=changes_{name}+1;', f'previous_{name}=b_{name};']
    lines += [f'previous_bundle={b_bundle};', 'end', 'end endtask', 'task print_changes; begin']
    for name in OUTPUTS:
        lines.append(f'$display("OUTPUT_COVERAGE name={name} changes=%0d", changes_{name});')
    lines += ['end endtask']
    return '\n'.join(lines) + '\n'

def run_command(command, folder, timeout, live_log=None):
    start = time.monotonic()
    try:
        if live_log:
            with live_log.open('w',encoding='utf-8') as stream:
                proc = subprocess.run(command,cwd=folder,stdout=stream,stderr=subprocess.STDOUT,text=True,timeout=timeout)
            log=live_log.read_text(encoding='utf-8',errors='replace')
        else:
            proc = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=timeout)
            log=proc.stdout+proc.stderr
        return dict(command=command, returncode=proc.returncode, log=log,
                    seconds=round(time.monotonic()-start, 3))
    except subprocess.TimeoutExpired as exc:
        out = live_log.read_text(encoding='utf-8',errors='replace') if live_log else exc.stdout or b''
        if isinstance(out, bytes):
            out = out.decode('utf-8', errors='replace')
        return dict(command=command, returncode=-1, log=out+'\nTIMEOUT', seconds=timeout)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-sha', help='Required current midi_keyboard SHA for a final frozen run')
    parser.add_argument('--baseline-selfcheck', action='store_true', help='Compare baseline against its own renamed copy')
    parser.add_argument('--mutation', choices=['held', 'receipt'], help='Negative control on a DERIVED current copy only')
    parser.add_argument('--seeds', default='1,203047,104729')
    parser.add_argument('--clock-hz', type=int, default=250000)
    args = parser.parse_args()
    if not args.baseline_selfcheck and not args.mutation and not args.expected_sha:
        parser.error('Final run requires --expected-sha; use --baseline-selfcheck while building the bench')
    names = ['src/midi_keyboard.v', 'src/midi_uart_rx.v',
             'tests/midi_bitmap_v047/midi_keyboard_before.v',
             'tests/midi_bitmap_v047/tb_midi_bitmap_diff.sv', 'tests/midi_bitmap_v047/run_diff.py']
    payloads = {n: (ROOT/n).read_bytes() for n in names}
    before = {n: digest(data) for n, data in payloads.items()}
    assert before[names[2]] == REFERENCE_SHA, 'Preserved reference was modified'
    if args.expected_sha:
        assert before[names[0]] == args.expected_sha.lower(), 'Frozen production SHA differs'
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out = HERE/'results'/stamp
    out.mkdir(parents=True)
    for n, data in payloads.items():
        target = out/'snapshot'/n
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    baseline = payloads[names[2]].decode('utf-8-sig')
    current = payloads[names[0]].decode('utf-8-sig')
    assert ports(current) == ports(baseline), 'Production interface changed'
    baseline, replacements = re.subn(r'\bmodule\s+midi_keyboard\b', 'module midi_keyboard_before', baseline, count=1)
    assert replacements == 1
    (out/'reference_derived.v').write_text(baseline, encoding='utf-8')
    if args.baseline_selfcheck or args.mutation:
        current = payloads[names[2]].decode('utf-8-sig')
    if args.mutation == 'held':
        old = 'held_notes[first_data]<=1;'
        assert current.count(old) == 1
        current = current.replace(old, 'held_notes[first_data]<=0;')
    elif args.mutation == 'receipt':
        old = 'assign receipt_note_on=rst_n && direct_event && key_on && !panic_request;'
        assert current.count(old) == 1
        current = current.replace(old, "assign receipt_note_on=1'b0;")
    (out/'current_derived.v').write_text(current, encoding='utf-8')
    (out/'interface_derived.vh').write_text(generated_interface(ports(baseline)), encoding='utf-8')
    command = [str(BIN/'iverilog.exe'), '-g2012', '-Wall', '-s', 'tb_midi_bitmap_diff', '-P', f'tb_midi_bitmap_diff.CLK_HZ={args.clock_hz}', '-I', str(out),
               '-o', str(out/'test.vvp'), str(out/'reference_derived.v'), str(out/'current_derived.v'),
               str(out/'snapshot'/names[1]), str(out/'snapshot'/names[3])]
    compiled = run_command(command, out, 60)
    (out/'compile.log').write_text(compiled.pop('log'), encoding='utf-8')
    runs = []
    def run_seed(seed):
        print(f'RUNNING seed={seed} clock_hz={args.clock_hz} timeout=900 log={out/f"run_seed_{seed}.log"}',flush=True)
        result = run_command([str(BIN/'vvp.exe'), '-i', str(out/'test.vvp'), f'+SEED={seed}'], out, 900, out/f'run_seed_{seed}.log')
        log = result.pop('log')
        result.update(seed=seed, log=str(out/f'run_seed_{seed}.log'))
        Path(result['log']).write_text(log, encoding='utf-8')
        match = re.search(r'BITMAP_DIFF_PASS (.+)', log)
        result['metrics'] = {k: int(v) for k,v in re.findall(r'(\w+)=(\d+)', match[1])} if match else {}
        result['case_passes'] = re.findall(r'CASE_PASS (.+)', log)
        result['output_changes'] = {k:int(v) for k,v in re.findall(r'OUTPUT_COVERAGE name=(\w+) changes=(\d+)', log)}
        result['negative_control_detected'] = args.mutation is not None and result['returncode'] != 0 and 'DIFF_FAIL' in log
        result['passed'] = result['returncode'] == 0 and match is not None
        print(log[-6500:], flush=True)
        return result
    if compiled['returncode']==0:
        seeds=[int(s) for s in args.seeds.split(',')]
        with ThreadPoolExecutor(max_workers=2) as pool:
            jobs=[pool.submit(run_seed,seed) for seed in seeds]
            for job in as_completed(jobs):runs.append(job.result())
        runs.sort(key=lambda r:r['seed'])
    after = {n: digest((ROOT/n).read_bytes()) for n in names}
    stable = before == after
    expected_success = bool(runs) and all(r['negative_control_detected'] if args.mutation else r['passed'] for r in runs)
    final = bool(args.expected_sha and not args.baseline_selfcheck and not args.mutation)
    report = dict(passed=compiled['returncode']==0 and expected_success and stable,
        final_frozen_comparison=final, baseline_selfcheck=args.baseline_selfcheck, mutation=args.mutation,
        source_sha256_before=before, source_sha256_after=after, all_snapshotted_inputs_unchanged=stable,
        tool_sha256={p.name:digest(p.read_bytes()) for p in (BIN/'iverilog.exe', BIN/'vvp.exe')},
        compared_outputs=OUTPUTS, compared_output_count=len(OUTPUTS),
        sampling='Every clock: pre-edge handshake values and post-NBA registered/combinational values, case inequality plus X rejection.',
        clock_hz=args.clock_hz, uart_baud=31250, uart_bit_cycles=args.clock_hz//31250, mapping_idle_cycles=(args.clock_hz//31250)*10,
        active_sense_ms=20, active_sense_cycles=(args.clock_hz//1000)*20, mapping_enable_parameter=1,
        runtime_mapper_modes=['disabled', 'enabled identity', 'enabled shifted bank1 directed raw-note case'],
        scope='Serial 8N1 pins, public ready/suppress/mapping ports only; read-only baseline internal flags used solely for collision coverage. No forced signals, no synthesized design, no hardware or network.',
        compile=compiled, runs=runs, result_path=str(out/'results.json'))
    report['two_seed_packaging_requirement_met']=report['passed'] and final and len({r['seed'] for r in runs})>=2
    (out/'results.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    label = 'final_latest.json' if final else 'selfcheck_latest.json' if args.baseline_selfcheck else 'mutation_latest.json'
    (HERE/label).write_text(json.dumps(report, indent=2), encoding='utf-8')
    summary = ['V047 MIDI bitmap differential verification', '',
        f'Passed: {report["passed"]}; frozen final comparison: {final}',
        f'Baseline SHA256: {before[names[2]]}', f'Current SHA256: {before[names[0]]}',
        f'All snapshot input hashes unchanged after run: {stable}',
        f'Outputs compared: {len(OUTPUTS)}; every pre-edge and post-NBA sample including invalid fields.',
        f'Real 31250baud UART frames at {args.clock_hz}Hz ({args.clock_hz//31250} clocks/bit); original mapping idle formula gives {(args.clock_hz//31250)*10} clocks.',
        f'Two distinct full seeds required for packaging: {report["two_seed_packaging_requirement_met"]}',
        'MAPPING_ENABLE=1 throughout, runtime disabled/identity-enabled stages plus shifted bank1 raw-note checks.',
        'ACTIVE_SENSE_MS=20 for accelerated timeout coverage; default 350ms and 27MHz timing are not certified here.',
        'Baseline is unchanged; only its derived module declaration is renamed. No production files edited.',
        'No Gowin build, resource/timing estimate, hardware flashing, or internet access.',
        f'Full results: {out / "results.json"}', '',
        *[f'Seed {r["seed"]}: passed={r["passed"]} metrics={r["metrics"]} log={r["log"]}' for r in runs]]
    (out/'report.txt').write_text('\n'.join(summary)+'\n', encoding='utf-8')
    if final:
        (HERE/'REPORT.txt').write_text('\n'.join(summary)+'\n', encoding='utf-8')
    print('RESULTS '+str(out/'results.json'), flush=True)
    return 0 if report['passed'] else 1

if __name__ == '__main__':
    sys.exit(main())
