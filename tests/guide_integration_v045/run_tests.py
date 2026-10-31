"""V045 boundary simulations. Writes ONLY within this new test directory.

Uses existing Icarus binaries and the existing pin-level MIDI test helper.
No install, synthesis, programming, external ports, or production modifications.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TOOLS = Path('D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
MIDI = ['src/midi_keyboard.v', 'src/midi_uart_rx.v', 'tests/tb_midi_support.v']
PANEL = ['src/four_button_display_control.v']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool-dir', type=Path, default=TOOLS)
    parser.add_argument('--only', help='Regex matching case names')
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=180, help='Per-process wall time; concurrent agents may load the host')
    parser.add_argument('--reuse-report', type=Path, action='append', default=[],
                        help='Reuse passing cases only with identical RTL/data/helper/bench hashes and parameters')
    args = parser.parse_args()
    bins = args.tool_dir.resolve()
    for exe in ('iverilog.exe', 'vvp.exe'):
        if not (bins / exe).is_file():
            raise SystemExit(f'Missing existing tool: {bins / exe}')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out = HERE / 'results' / stamp
    snapshot = out / 'snapshot'
    snapshot.mkdir(parents=True)
    # Full src snapshot allows real audio_top elaboration and all readmem files.
    inputs = sorted(p for p in (ROOT / 'src').rglob('*') if p.is_file())
    inputs += sorted(HERE.glob('tb_*.v')) + [Path(__file__).resolve(), ROOT / 'tests/tb_midi_support.v']
    inputs += [ROOT / 'tests/tb_v035_panel_buttons.v', ROOT / 'tests/tb_fourphone_buttons.v']
    inputs += [ROOT / 'tests/song_library_v045/source.json']
    hashes = {}
    for src in inputs:
        relative = src.relative_to(ROOT).as_posix()
        content = src.read_bytes()
        dest = snapshot / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
        hashes[relative] = hashlib.sha256(content).hexdigest()
    # Independent event oracle: raw pitch/duration pairs, never DUT HEX/functions.
    raw_songs = json.loads((snapshot / 'tests/song_library_v045/source.json').read_text(encoding='utf-8'))
    event_words, meta_words, song_summary = [], [], []
    for sid, song in enumerate(raw_songs['songs']):
        assert song['id'] == sid
        pairs = song['events_note_duration_quarters']
        cursor, words = 128, []
        for pitch, quarters in pairs:
            assert pitch == 0 or 41 <= pitch <= 72
            end = cursor + quarters * 16
            assert quarters > 0 and end < 4096
            words.append((cursor << 20) | (end << 8) | pitch)
            cursor = end
        pitched = sum(p != 0 for p, _ in pairs)
        assert len(pairs) <= 63 and cursor % 64 == 0
        event_words.extend(words + [0] * (64 - len(words)))
        meta_words.append(len(pairs) | (pitched << 8) | ((cursor // 64) << 16) | ((len(pairs) - pitched) << 24))
        song_summary.append({'id': sid, 'title': song['title'], 'steps': len(pairs),
                             'pitched_events': pitched, 'rests': len(pairs) - pitched, 'total_beats': cursor // 64})
    for filename, words in [('song_events.hex', event_words), ('song_metadata.hex', meta_words)]:
        (snapshot / 'tests/guide_integration_v045' / filename).write_text(''.join(f'{v:08x}\n' for v in words), encoding='ascii')
    (out / 'song_oracle.json').write_text(json.dumps(song_summary, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    rtl = sorted(str(p.relative_to(snapshot)).replace('\\', '/') for p in (snapshot / 'src').glob('*.v'))
    cases = []
    def add(name, top, sources, params=None, marker=None, bench=None):
        cases.append((name, top, sources, params or {}, marker or 'V045_' + top.removeprefix('tb_').upper() + '_PASS',
                      bench or f'tests/guide_integration_v045/{top}.v'))
    for hz in (1000000, 27000000):
        add(f'receipt_{hz}', 'tb_receipt', MIDI, {'CLK_HZ': hz})
    add('demo_real_allocator', 'tb_demo_allocator', ['src/guide_demo_events.v', 'src/voice_allocator.v'])
    for db in (1, 4):
        add(f'menu_db{db}', 'tb_menu', PANEL, {'DB': db})
    for enable in (0, 1):
        add(f'phone_enable{enable}', 'tb_phone', ['src/phone_extension_state.v'] + PANEL, {'ENABLE': enable})
        add(f'guide_stop_enable{enable}', 'tb_guide_stop', PANEL, {'ENABLE': enable})
    add('hub_receipt_backpressure', 'tb_hub_receipt', MIDI + ['src/performance_input_hub.v'])
    if (HERE / 'tb_audio_chain.v').exists():
        add('audio_chain_real_rtl', 'tb_audio_chain', rtl + ['tests/tb_midi_support.v'])
    score_rtl = ['src/piano_roll_guide.v', 'src/piano_builtin_score_ram.v',
                 'src/guide_play_modes.v', 'src/guide_demo_events.v', 'src/voice_allocator.v']
    for mode in (0, 1, 2):
        for gap in ((4,) if mode == 0 else (1, 4)):
            add(f'score_modes_m{mode}_gap{gap}', 'tb_score_modes', score_rtl, {'MODE': mode, 'GAP': gap})
    add('legacy_panel_v035', 'tb_v035_panel_buttons', PANEL, marker='V035_PANEL_BUTTONS_PASS',
        bench='tests/tb_v035_panel_buttons.v')
    add('legacy_fourphone', 'tb_fourphone_buttons', PANEL, marker='FOURPHONE_BUTTONS_PASS',
        bench='tests/tb_fourphone_buttons.v')
    if args.only:
        cases = [c for c in cases if re.search(args.only, c[0])]
    if not cases:
        raise SystemExit('No selected cases')
    env = dict(os.environ, PATH=str(bins) + os.pathsep + os.environ.get('PATH', ''))
    failure = re.compile(r'(?im)^\s*(?:FATAL:|ERROR:)|\bTIMEOUT\b')
    reuse = []
    for report_path in args.reuse_report:
        old = json.loads(report_path.read_text(encoding='utf-8'))
        for record in old.get('tests', []):
            if record.get('passed'):
                reuse.append((report_path.resolve(), old.get('source_sha256', {}), record))

    def execute(label, argv):
        started = time.monotonic()
        try:
            result = subprocess.run(list(map(str, argv)), cwd=snapshot, env=env, capture_output=True,
                                    text=True, encoding='utf-8', errors='replace', timeout=args.timeout)
            code, log = result.returncode, result.stdout + result.stderr
        except subprocess.TimeoutExpired as exc:
            partial = exc.stdout or b''
            if isinstance(partial, bytes):
                partial = partial.decode('utf-8', errors='replace')
            code, log = -1, partial + f'\nTIMEOUT {exc}'
        (out / f'{label}.log').write_text(log, encoding='utf-8')
        return {'exit_code': code, 'log': str(out / f'{label}.log'), 'argv': list(map(str, argv)),
                'wall_seconds': round(time.monotonic() - started, 3)}, log

    def test(case):
        name, top, sources, params, marker, bench = case
        # Conservatively compare ALL production RTL/includes/ROM images as well
        # as this case's bench and existing helper; runner-only edits don't turn
        # an unchanged HDL simulation into new evidence.
        required = [p for p in hashes if p.startswith('src/')]
        required += [bench] + [p for p in sources if p.startswith('tests/')]
        if top == 'tb_score_modes':
            required += ['tests/song_library_v045/source.json']
        for old_path, old_hashes, old_record in reversed(reuse):
            if (old_record['name'] == name and old_record.get('parameters', {}) == params
                    and all(old_hashes.get(p) == hashes.get(p) for p in required)
                    and Path(old_record.get('simulation', {}).get('log', '')).is_file()):
                record = dict(old_record, reused_from=str(old_path))
                print(f'{name}: PASS (identical input hashes; reused)', flush=True)
                return record
        binary = out / f'{name}.vvp'
        compile_result, log = execute(name + '_compile', [bins / 'iverilog.exe', '-g2012', '-Wall', '-s', top,
            *[f'-P{top}.{k}={v}' for k, v in params.items()], '-o', binary, *sources, bench])
        record = {'name': name, 'compile': compile_result, 'passed': False, 'top': top, 'parameters': params}
        if compile_result['exit_code'] == 0:
            simulation, log = execute(name, [bins / 'vvp.exe', binary])
            record['simulation'] = simulation
            record['passed'] = simulation['exit_code'] == 0 and marker in log and not failure.search(log)
            record['case_passes'] = [line for line in log.splitlines() if '_PASS' in line]
        print(f'{name}: {"PASS" if record["passed"] else "FAIL"}', flush=True)
        if not record['passed']:
            print(log[-3500:], flush=True)
        return record
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        records = list(pool.map(test, cases))
    changed = [p for p, digest in hashes.items()
               if not (ROOT / p).exists() or hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != digest]
    report = {'passed': all(r['passed'] for r in records), 'utc': stamp, 'test_count': len(records),
              'passed_count': sum(r['passed'] for r in records), 'tests': records, 'source_sha256': hashes,
              'inputs_changed_during_run': changed, 'snapshot_matches_current_inputs': not changed,
              'results_directory': str(out), 'tool_dir': str(bins), 'fpga_compiled': False,
              'reuse_count': sum('reused_from' in r for r in records), 'song_oracle': song_summary,
              'flashed': False, 'hardware_tested': False, 'production_edits_by_runner': False}
    text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    (out / 'report.json').write_text(text, encoding='utf-8')
    (HERE / 'latest_report.json').write_text(text, encoding='utf-8')
    print(f'Report: {out / "report.json"}', flush=True)
    if changed:
        print(f'Concurrent input changes: {changed}', flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
