"""Render real V027/V028 RTL RGB and check current titles/four-key footer.

Run from either project root with a Python that provides Pillow:
  python scripts/run_four_key_ui_render.py
Writes ONLY validation/four_key_ui_render. No synthesis/programming/assets edits.
Oracle text is independent of hdmi_ui_text.vh and of the DUT's character ROM.
Pillow only decodes captures, crops/assembles previews and compares pixels.
"""
from pathlib import Path
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time
import traceback
from toolchain import find_icarus, ToolchainError

ROOT = Path(__file__).resolve().parents[1]
BG = (11, 16, 28)
TEXT = (226, 232, 240)
CYAN = (81, 214, 232)
GREEN = (33, 198, 168)
AMBER = (244, 187, 79)
MASKS = [0, 1, 2, 4, 8, 3, 12, 15]
PAGES = ['live', 'library', 'help', 'diagnostic', 'oscillator32']


def read_text(path):
    return path.read_text(encoding='utf-8', errors='replace')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_manifest():
    # Only the real renderer compilation/font/text dependencies belong to this
    # proof. Audio/control edits in parallel cannot affect these pixel captures.
    inputs = ['src/hdmi_compact_dashboard.v', 'src/hdmi_ui_font.v',
              'src/piano_roll_renderer.v', 'src/piano_roll_score.v',
              'src/piano_layout.vh', 'src/hdmi_ui_text.vh', 'src/hdmi_ui_lookup.vh',
              'src/ui_font.hex', 'assets/ui_texts.json', 'assets/ui_font_map.json']
    return {name: digest(ROOT/name) for name in inputs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool-bin', type=Path, help='Override IVERILOG_BIN/PATH discovery')
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--all-page-masks', action='store_true',
                        help='Optional expanded coverage; default is five full pages plus LIVE masks only')
    parser.add_argument('--reuse-captures', action='store_true',
                        help='Recheck existing captures only if source, testbench and PPM hashes still match')
    args = parser.parse_args()
    try:
        tools = find_icarus(args.tool_bin)
    except ToolchainError as exc:
        parser.error(str(exc))
    out = ROOT/'validation/four_key_ui_render'
    out.mkdir(parents=True, exist_ok=True)
    piano = True  # This V031 project retains the V030 phone/piano configuration.
    version = json.loads((ROOT/'manifest.json').read_text(encoding='utf-8-sig'))['version']
    before = source_manifest()
    report = dict(schema_version=1, version=version, passed=False, status='RUNNING',
                  started_utc=datetime.now(timezone.utc).isoformat(),
                  project=str(ROOT), cwd=str(ROOT), tools=tools.as_dict(),
                  parameters={'PIANO_ROLL_ENABLE': 1 if piano else 'parameter absent'},
                  hardware_programmed=False, gowin_build_run=False, synthesis_run=False,
                  physical_hdmi_validated=False, debounce_validated=False,
                  source_hashes_before=before, commands=[], cases=[], failures=[],
                  oracle='Literal current UI text + assets/ui_font_map.json + src/ui_font.hex; no DUT internals or old menu oracle',
                  preview_provenance='Icarus DUT RGB -> binary PPM -> lossless PNG; contact sheets only paste captured pixels',
                  pipeline_contract='input sampled on edge N; RGB valid after edge N+1 (two registered stages)',
                  footer_contract={'x': 320, 'y': 464, 'width': 256, 'height': 16,
                                   'bit_order': 'ui_controls[0] -> KEY1 through [3] -> KEY4',
                                   'masks_binary_msb_first': [f'{v:04b}' for v in MASKS]},
                  scope='Renderer simulation with synthetic inputs only; upstream debounce/CDC/wrapper/physical HDMI are not tested')
    env = tools.environment()

    def run(name, argv, marker=None, timeout=240):
        start = time.monotonic()
        result = subprocess.run(list(map(str, argv)), cwd=ROOT, env=env, capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=timeout)
        log = result.stdout + result.stderr
        (out/(name+'.log')).write_text(log, encoding='utf-8')
        record = dict(name=name, argv=list(map(str, argv)), exit_code=result.returncode,
                      seconds=round(time.monotonic()-start, 3), log=str(out/(name+'.log')),
                      passed=result.returncode == 0 and 'FATAL:' not in log and (marker is None or marker in log))
        report['commands'].append(record)
        return record, log

    try:
        from PIL import Image
        reused = None
        if args.reuse_captures:
            reused = json.loads(read_text(out/'summary.json'))
            if (reused['source_hashes_before'] != before or
                    reused['source_hashes_after'] != before or
                    reused['test_hashes']['tests/tb_four_key_ui_render.v'] != digest(ROOT/'tests/tb_four_key_ui_render.v')):
                raise RuntimeError('Cannot reuse captures: source/assets/testbench changed')
            report['reused_captures_from_utc'] = reused['completed_utc']
        report['tool_hashes'] = {name: digest(path) for name, path in
                                 [('iverilog', tools.iverilog), ('vvp', tools.vvp)]}
        report['python'] = sys.executable
        font_map = json.loads(read_text(ROOT/'assets/ui_font_map.json'))['hanzi']
        font = bytes(int(v, 16) for v in read_text(ROOT/'src/ui_font.hex').split())
        if len(font) != 8192:
            raise RuntimeError('Expected original 8192-byte font ROM')

        def cells(text, width=32):
            result = []
            for char in text:
                result.extend([ord(char)] if ord(char) < 128 else font_map[char])
            if len(result) > width:
                raise ValueError('Oracle text too long: '+text)
            return result + [32]*(width-len(result))

        def colour(text, dx, dy, ink=TEXT, width=32):
            glyph = cells(text, width)[dx//8]
            return ink if font[glyph*16+dy] & (1 << (7-dx%8)) else BG

        titles = [version+' 演奏 / '+('PHONE' if piano else '4 KEYS'), version+' 曲库',
                  version+' 操作说明', version+' 接线诊断', version+' 32路验证']

        def footer(mask):
            return ' '.join(f'KEY{k+1}:{(mask >> k) & 1}' for k in range(4))

        def compare(image, text, x, y, ink=TEXT, width=32):
            codes = cells(text, width)
            wrong = 0
            examples = []
            for dy in range(16):
                for dx in range(width*8):
                    wanted = ink if font[codes[dx//8]*16+dy] & (1 << (7-dx%8)) else BG
                    actual = image.getpixel((x+dx, y+dy))
                    if actual != wanted:
                        wrong += 1
                        if len(examples) < 6:
                            examples.append({'xy': [x+dx, y+dy], 'expected': wanted, 'actual': actual})
            return dict(text=text, rectangle=[x, y, width*8, 16], checked_pixels=width*128,
                        mismatched_pixels=wrong, passed=wrong == 0, first_mismatches=examples)

        executable = out/'tb_four_key_ui_render.vvp'
        sources = ['src/hdmi_compact_dashboard.v', 'src/hdmi_ui_font.v']
        if piano:
            sources += ['src/piano_roll_renderer.v', 'src/piano_roll_score.v']
        cmd = [tools.iverilog, '-g2012', '-Wall', '-I', '.',
               '-s', 'tb_four_key_ui_render', '-o', executable]
        if piano:
            cmd += ['-DFOUR_KEY_PIANO']
        compiled, _ = run('compile', cmd+sources+['tests/tb_four_key_ui_render.v'])
        if not compiled['passed']:
            raise RuntimeError('Icarus compile failed; see compile.log')

        # An independent timing oracle drives unrelated pixels/status every clock.
        # Known text/solid colours establish latency, including transitions into
        # and out of blanking, and the actual piano overlay on V028.
        rng = random.Random(20261030)
        vectors = []
        categories = dict(title=0, dynamic_footer=0, blank_de=0, blank_x=0, blank_y=0,
                          background=0, piano_overlay=0)
        for i in range(8192):
            case = i % 8
            scene = rng.randrange(5)
            page = min(scene, 3)
            test = int(scene == 4)
            mask = rng.randrange(16)
            if case <= 1:
                dx, dy = rng.randrange(256), rng.randrange(16)
                x, y, de = 32+dx, 16+dy, 1
                expected = colour(titles[scene], dx, dy, CYAN)
                category = 'title'
            elif case == 2:
                # Help page is common to both variants. All 16 bit patterns
                # change per clock to test numeric override register alignment.
                page, test = 2, 0
                digit = rng.randrange(4)
                dx, dy = (5+7*digit)*8+rng.randrange(8), rng.randrange(16)
                x, y, de = 320+dx, 464+dy, 1
                expected = colour(footer(mask), dx, dy)
                category = 'dynamic_footer'
            elif case == 3:
                x, y, de, expected = rng.randrange(640), rng.randrange(480), 0, (0, 0, 0)
                category = 'blank_de'
            elif case == 4:
                x, y, de, expected = rng.choice([640, 641, 799, 1023]), rng.randrange(480), 1, (0, 0, 0)
                category = 'blank_x'
            elif case == 5:
                x, y, de, expected = rng.randrange(640), rng.choice([480, 481, 524, 1023]), 1, (0, 0, 0)
                category = 'blank_y'
            elif case == 6 and piano:
                page, test, de, y = 0, 0, 1, 375
                x, expected = rng.choice([(40, TEXT), (380, GREEN), (410, (255, 89, 100)), (605, (52, 70, 95))])
                category = 'piano_overlay'
            else:
                x, y, de, expected = rng.choice([0, 1, 639]), rng.randrange(480), 1, BG
                category = 'background'
            categories[category] += 1
            vectors.append(f'{x} {y} {de} {page} {test} {mask} {bytes(expected).hex()}\n')
        vector_path = out/'pipeline_blanking.vec'
        vector_path.write_text(''.join(vectors), encoding='ascii')
        probe, log = run('pipeline_blanking', [tools.vvp, executable, '+PROBE='+vector_path.as_posix()], 'FOUR_KEY_UI_RENDER_PASS')
        report['pipeline_blanking'] = dict(passed=probe['passed'], vectors=len(vectors), categories=categories)
        match = re.search(r'FOUR_KEY_PROBE checks=(\d+) stable=(\d+) resets=(\d+) errors=(\d+)', log)
        if match:
            report['pipeline_blanking'].update(zip(['checked_outputs', 'preclock_stability_checks', 'reset_checks', 'errors'], map(int, match.groups())))
        print(version, 'pipeline/blanking', 'PASS' if probe['passed'] else 'FAIL', flush=True)

        def render_case(scene, mask):
            # Full four pages + test page; additional full LIVE snapshots for
            # every onehot/chord. Other page/mask combinations capture the
            # actual bottom 32 rows, including both possible footer positions.
            full = mask == 0
            first_y = 0 if full else 448
            name = f'{PAGES[scene]}_keys_{mask:04b}'
            ppm = out/(name+'.ppm')
            argv = [tools.vvp, executable, f'+SCENE={scene}', f'+CONTROL={mask}', '+PPM='+ppm.as_posix()]
            if not full:
                argv += ['+FOOTER_ONLY']
            if reused is None:
                record, log = run('render_'+name, argv, 'FOUR_KEY_UI_RENDER_PASS')
            else:
                old = next(c for c in reused['cases'] if c['name'] == name)
                if old.get('capture_ppm_sha256') is not None:
                    if old['capture_ppm_sha256'] != digest(ppm):
                        raise RuntimeError('Cannot reuse capture: hash mismatch '+name)
                else:
                    # Earlier runner revisions recorded PNG hashes. Verify both
                    # that hash and exact decoded PPM pixels before accepting.
                    old_png = Path(old['preview_png'])
                    if digest(old_png) != old['preview_sha256']:
                        raise RuntimeError('Cannot reuse PNG: hash mismatch '+name)
                    with Image.open(old_png) as previous, Image.open(ppm) as raw:
                        if previous.size != raw.size or previous.convert('RGB').tobytes() != raw.convert('RGB').tobytes():
                            raise RuntimeError('Cannot reuse PPM: pixel mismatch '+name)
                record = dict(next(c for c in reused['commands'] if c['name'] == 'render_'+name))
                record['reused_capture'] = True
                report['commands'].append(record)
                log = read_text(out/('render_'+name+'.log'))
            result = dict(name=name, scene=scene, page=PAGES[scene], ui_controls=f'{mask:04b}',
                          ui_controls_decimal=mask, full_frame=full, capture_origin=[0, first_y],
                          simulation_passed=record['passed'], checks={}, passed=False)
            match = re.search(r'pixels=(\d+) blanking=(\d+) errors=(\d+)', log)
            if match:
                result.update(zip(['captured_pixels', 'blanking_checks', 'simulation_errors'], map(int, match.groups())))
            if not ppm.exists():
                result['error'] = 'Missing actual RTL capture'
                return result
            with Image.open(ppm) as source:
                im = source.convert('RGB')
            if im.size != (640, 480-first_y):
                raise RuntimeError('Incomplete capture '+name)
            png = ppm.with_suffix('.png')
            im.save(png)
            result['preview_png'] = str(png)
            result['preview_sha256'] = digest(png)
            result['capture_ppm_sha256'] = digest(ppm)
            checks = result['checks']
            checks['footer'] = compare(im, footer(mask), 320, 464-first_y)
            checks['footer_digits'] = [compare(im, str((mask >> k) & 1), 320+8*(5+7*k), 464-first_y, width=1) for k in range(4)]
            if full:
                checks['version_title'] = compare(im, titles[scene], 32, 16, CYAN)
                if scene == 0 and piano:
                    checks['live_navigation_1'] = compare(im, '1 PAGE  2 PLAY/PAUSE', 32, 448)
                    checks['live_navigation_2'] = compare(im, '3 RESTART  4 SONG', 32, 464)
                    checks['fx_labels'] = compare(im, 'K1 DELAY K2 CHOR K3 REV K4 VOL', 32, 416)
                    checks['fx_targets'] = compare(im, 'DL 064 CH 096 RV 128 VL 192', 320, 448)
                if scene == 0 and not piano:
                    checks['main_band11_four_keys'] = compare(im, '4 KEYS: 界面操作', 32, 368, AMBER)
                if scene == 2:
                    # New four-key instructions, independently specified.
                    labels = [('page_key', '1 切换界面', 32, 80),
                              ('play_key', '2 PLAY / PAUSE', 32, 112),
                              ('restart_key', '3 重开当前曲', 32, 144),
                              ('next_key', '4 选择下一曲', 320, 144),
                              ('release_action', '按住:状态 释放:操作', 32, 176),
                              ('multiple_keys_cancel', '多键同时按下:无操作', 320, 176),
                              ('state_legend', '0=释放 1=按下', 32, 208),
                              ('hold_timbre', '1 HOLD: NEXT TIMBRE', 32, 336),
                              ('hold_mode', '2 HOLD: KEY > STRUM > HYBRID', 320, 336),
                              ('hold_release', 'HOLD >=0.8s THEN RELEASE', 32, 368)]
                    for label, text, x, y in labels:
                        checks[label] = compare(im, text, x, y)
                if scene == 4:
                    checks['request_32'] = compare(im, '32', 32+8*8, 48, GREEN, width=2)
                    checks['active_32'] = compare(im, '32', 32+18*8, 48, GREEN, width=2)
                    checks['gate_mask'] = compare(im, 'FFFFFFFF', 32+7*8, 80, GREEN, width=8)
                    checks['busy_mask'] = compare(im, 'FFFFFFFF', 320+7*8, 80, GREEN, width=8)
            all_checks = [entry for value in checks.values() for entry in (value if isinstance(value, list) else [value])]
            result['passed'] = record['passed'] and all(c['passed'] for c in all_checks)
            result['mismatched_pixels'] = sum(c['mismatched_pixels'] for key, c in checks.items() if isinstance(c, dict))
            print(version, name, 'PASS' if result['passed'] else 'FAIL', 'pixel_mismatches='+str(result['mismatched_pixels']), flush=True)
            return result

        combinations = ([(c['scene'], c['ui_controls_decimal']) for c in reused['cases']] if reused else
                        [(scene, mask) for scene in range(5) for mask in MASKS] if args.all_page_masks else
                        [(scene, 0) for scene in range(5)] + [(0, mask) for mask in MASKS if mask])
        report['coverage_pairs'] = combinations
        with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 2))) as pool:
            jobs = [pool.submit(render_case, scene, mask) for scene, mask in combinations]
            report['cases'] = [job.result() for job in jobs]

        # Contact sheets contain only unmodified captured pixels. Layout/order
        # is in the JSON/README; no fonts or fake interface elements are drawn.
        pages = Image.new('RGB', (640*3, 480*2), BG)
        for i, scene in enumerate(range(5)):
            with Image.open(out/f'{PAGES[scene]}_keys_0000.png') as im:
                pages.paste(im, ((i % 3)*640, (i//3)*480))
        pages.save(out/'pages_overview.png')
        sheet = Image.new('RGB', (640*2, 32*((len(report['cases'])+1)//2)), BG)
        for i, case in enumerate(report['cases']):
            with Image.open(case['preview_png']) as im:
                crop = im.crop((0, 448, 640, 480)) if case['full_frame'] else im
                sheet.paste(crop, ((i % 2)*640, (i//2)*32))
        sheet.save(out/'footer_states_overview.png')
        report['overview_pngs'] = [str(out/'pages_overview.png'), str(out/'footer_states_overview.png')]
        report['failures'] = [c['name'] for c in report['cases'] if not c['passed']]
        if piano and any(not c['checks']['footer']['passed'] for c in report['cases'] if c['scene'] == 0):
            report['findings'] = [{
                'id': 'V028_LIVE_FOOTER_OFFSCREEN', 'severity': 'bug',
                'file': str(ROOT/'src/hdmi_compact_dashboard.v'),
                'evidence': 'LIVE captures have no KEY1..KEY4 at y=464..479; title and other page footer checks are reported separately.',
                'cause': 'piano_live local_y=y-32 for y>=416: band14 starts at y=480; y464..479 also has local_y[4]=1 so text_window is false.',
                'expected': 'All four debounced controls visibly shown on LIVE as on all other pages.',
                'suggested_fix': 'Give BUTTON_STATES an explicit visible 16-pixel footer window (e.g. y464..479) with aligned glyph rows, or deliberately assign an existing visible row.',
                'source_modified_by_this_test': False}]
        report['passed'] = compiled['passed'] and probe['passed'] and not report['failures']
    except Exception as exc:
        report['exception'] = str(exc)
        (out/'runner_exception.log').write_text(traceback.format_exc(), encoding='utf-8')
        print(version, 'ERROR', str(exc), flush=True)
        report['passed'] = False
    finally:
        after = source_manifest()
        report['source_hashes_after'] = after
        report['source_assets_unchanged'] = before == after
        report['changed_source_paths'] = [p for p in sorted(set(before) | set(after)) if before.get(p) != after.get(p)]
        report['test_hashes'] = {p: digest(ROOT/p) for p in ['tests/tb_four_key_ui_render.v', 'scripts/run_four_key_ui_render.py']}
        report['passed'] = report['passed'] and report['source_assets_unchanged']
        report['status'] = 'PASS' if report['passed'] else 'FAIL'
        report['completed_utc'] = datetime.now(timezone.utc).isoformat()
        report['totals'] = dict(cases=len(report['cases']), passed_cases=sum(c['passed'] for c in report['cases']),
                                failed_cases=sum(not c['passed'] for c in report['cases']),
                                full_frames=sum(c['full_frame'] for c in report['cases']),
                                captured_pixels=sum(c.get('captured_pixels', 0) for c in report['cases']),
                                blanking_checks=sum(c.get('blanking_checks', 0) for c in report['cases']))
        (out/'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        readme = [f'{version}: {report["status"]}', '',
                  'All PNGs are actual RTL RGB. Stimulus is synthetic; no hardware verification.',
                  'pages_overview.png order: live, library, help / diagnostic, oscillator32.',
                  'footer_states_overview.png: row-major in summary.json cases order.',
                  'Default coverage: five full pages at 0000, plus LIVE onehot/0011/1100/1111.',
                  'Expanded earlier coverage is retained when --reuse-captures is used.',
                  'KEY1 is bit0; KEY4 is bit3. Footer captures include original y448..479.',
                  'Full frames: all five modes at 0000, plus seven LIVE key-state frames.',
                  'Detailed pixel comparisons, source hashes and command logs: summary.json.',
                  'Two-stage/blanking/reset details: pipeline_blanking.log.', '',
                  'Failing cases: '+', '.join(report['failures'])]
        for finding in report.get('findings', []):
            readme += ['', finding['id'], finding['cause'], finding['suggested_fix']]
        (out/'README.txt').write_text('\n'.join(readme)+'\n', encoding='utf-8')
        print(version, report['status'], str(out/'summary.json'), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
