"""V034 HDMI modes: bundled CDC compatibility and literal-text RGB oracles.

Run using the installed Pillow Python. No FPGA build or hardware access.
All captures come from Icarus RTL; Pillow only decodes and compares pixels.
Snapshots include ONLY display dependencies, so parallel audio edits are safe.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from toolchain import find_icarus

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['src/hdmi_live_display.v', 'src/hdmi_compact_dashboard.v',
           'src/hdmi_status_cdc.v', 'src/hdmi_instrument_dashboard.v',
           'src/piano_roll_renderer.v', 'src/piano_roll_score.v',
           'src/hdmi_ui_font.v', 'src/wave_scope.v', 'src/video_timing.v']
INPUTS = SOURCES + ['src/hdmi_ui_text.vh', 'src/hdmi_ui_lookup.vh',
                   'src/piano_layout.vh', 'src/ui_font.hex',
                   'assets/ui_texts.json', 'assets/ui_font_map.json',
                   'tests/tb_hdmi_hybrid_cdc.v', 'tests/tb_piano_roll_cdc.v',
                   'tests/tb_compact_dashboard.v', 'tests/tb_four_key_ui_render.v',
                   'tests/tb_piano_roll_pixels.v', 'scripts/run_hdmi_hybrid_tests.py',
                   'scripts/toolchain.py']
BG = (11, 16, 28)
CYAN = (81, 214, 232)
TEXT = (226, 232, 240)
GREEN = (33, 198, 168)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    tools = find_icarus()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out = ROOT/'validation/hdmi_v034'/stamp
    snapshot = out/'snapshot'
    for name in INPUTS:
        dest = snapshot/name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/name, dest)
    hashes = {name: sha(snapshot/name) for name in INPUTS}
    env = tools.environment()
    report = dict(passed=False, source_hashes=hashes, commands=[], captures=[],
                  cwd=str(snapshot), python=sys.executable, tools=tools.as_dict(),
                  packet_widths=[339, 290, 338, 289, 252, 242],
                  hardware_programmed=False, synthesis_run=False,
                  physical_hdmi_validated=False,
                  mode_contract={'0': 'KEYBOARD', '1': 'STRUM', '2': 'HYBRID'})

    def run(name, argv, marker=None):
        start = time.monotonic()
        result = subprocess.run(list(map(str, argv)), cwd=snapshot, env=env,
                                capture_output=True, text=True, encoding='utf-8',
                                errors='replace', timeout=240)
        log = result.stdout+result.stderr
        (out/(name+'.log')).write_text(log, encoding='utf-8')
        rec = dict(name=name, argv=list(map(str, argv)), exit_code=result.returncode,
                   seconds=round(time.monotonic()-start, 3),
                   passed=result.returncode == 0 and 'FATAL:' not in log and
                          (marker is None or marker in log))
        report['commands'].append(rec)
        print(name, 'PASS' if rec['passed'] else 'FAIL', flush=True)
        if not rec['passed']:
            raise RuntimeError(name+' failed: '+log[-2000:])
        return log

    def compile_bench(top, bench, extras=(), defines=()):
        executable = out/(top+'.vvp')
        run('compile_'+top, [tools.iverilog, '-g2012', '-Wall', '-I', '.',
                            '-s', top, '-o', executable, *defines, *SOURCES,
                            bench, *extras])
        return executable

    font = bytes(int(v, 16) for v in (snapshot/'src/ui_font.hex').read_text().split())
    font_map = json.loads((snapshot/'assets/ui_font_map.json').read_text(encoding='utf-8'))['hanzi']

    def compare(image, text, x, y, ink=TEXT, width=32):
        cells = []
        for char in text:
            cells.extend([ord(char)] if ord(char) < 128 else font_map[char])
        assert len(cells) <= width
        cells += [32]*(width-len(cells))
        mismatches = []
        count = 0
        for dy in range(16):
            for dx in range(width*8):
                expected = ink if font[cells[dx//8]*16+dy] & (1 << (7-dx%8)) else BG
                actual = image.getpixel((x+dx, y+dy))
                if actual != expected:
                    count += 1
                    if len(mismatches) < 4:
                        mismatches.append(dict(x=x+dx, y=y+dy, expected=expected, actual=actual))
        return dict(text=text, checked_pixels=width*128,
                    mismatched_pixels=count, passed=count == 0, first_mismatches=mismatches)

    try:
        hybrid = compile_bench('tb_hdmi_hybrid_cdc', 'tests/tb_hdmi_hybrid_cdc.v',
                               ['tests/tb_compact_dashboard.v'])
        legacy = compile_bench('tb_piano_roll_cdc', 'tests/tb_piano_roll_cdc.v',
                               ['tests/tb_compact_dashboard.v'])
        pixels = compile_bench('tb_piano_roll_pixels', 'tests/tb_piano_roll_pixels.v')
        capture = compile_bench('tb_four_key_ui_render', 'tests/tb_four_key_ui_render.v',
                                defines=['-DFOUR_KEY_PIANO'])
        jobs = [('hybrid_cdc', hybrid, 'HDMI_HYBRID_CDC_PASS'),
                ('legacy_cdc', legacy, 'PIANO_ROLL_CDC_PASS'),
                ('piano_pixels', pixels, 'PIANO_ROLL_PIXELS_PASS')]
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(run, name, [tools.vvp, exe], marker)
                       for name, exe, marker in jobs]
            for future in futures:
                future.result()

        titles = ['V034 演奏 / PHONE', 'V034 曲库', 'V034 操作说明',
                  'V034 接线诊断', 'V034 32路验证']
        labels = ['MODE KEYBOARD', 'MODE STRUM', 'MODE HYBRID']

        def render(scene, mode, full=False):
            name = f'page{scene}_mode{mode}'+('_full' if full else '_header')
            ppm = out/(name+'.ppm')
            argv = [tools.vvp, capture, f'+SCENE={scene}', f'+MODE={mode}',
                    '+CONTROL=9', f'+PPM={ppm.as_posix()}']
            if not full:
                argv += ['+HEADER_ONLY']
            run('render_'+name, argv, 'FOUR_KEY_UI_RENDER_PASS')
            with Image.open(ppm) as raw:
                im = raw.convert('RGB')
            assert im.size == (640, 480 if full else 32)
            png = ppm.with_suffix('.png')
            im.save(png)
            checks = [compare(im, titles[scene], 32, 16, CYAN),
                      compare(im, labels[mode], 320, 16, CYAN)]
            if full:
                checks += [compare(im, 'KEY1:1 KEY2:0 KEY3:0 KEY4:1', 320, 464)]
                if scene == 0:
                    checks += [compare(im, '1 PAGE  2 PLAY/PAUSE', 32, 448),
                               compare(im, '3 RESTART  4 SONG', 32, 464),
                               compare(im, 'K1 DELAY K2 CHOR K3 REV K4 VOL', 32, 416)]
                if scene == 2:
                    checks += [compare(im, '1 切换界面', 32, 80),
                               compare(im, '2 PLAY / PAUSE', 32, 112),
                               compare(im, '3 重开当前曲', 32, 144),
                               compare(im, '4 选择下一曲', 320, 144),
                               compare(im, '1 HOLD: NEXT TIMBRE', 32, 336),
                               compare(im, '2 HOLD: KEY > STRUM > HYBRID', 320, 336),
                               compare(im, 'HOLD >=0.8s THEN RELEASE', 32, 368)]
            record = dict(name=name, scene=scene, mode=mode, full_frame=full,
                          png=str(png), png_sha256=sha(png), checks=checks,
                          passed=all(c['passed'] for c in checks))
            if not record['passed']:
                raise AssertionError(json.dumps(record, ensure_ascii=False))
            return record

        cases = [(page, mode, False) for page in range(5) for mode in range(3)]
        cases += [(0, 2, True), (2, 2, True)]
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(render, *case) for case in cases]
            report['captures'] = [future.result() for future in futures]
        # This contact sheet is pasted unmodified RTL, with no synthetic labels.
        sheet = Image.new('RGB', (640*3, 32*5), BG)
        for case in report['captures']:
            if not case['full_frame']:
                with Image.open(case['png']) as im:
                    sheet.paste(im, (case['mode']*640, case['scene']*32))
        sheet.save(out/'mode_headers.png')
        report['header_preview'] = str(out/'mode_headers.png')
        report['source_hashes_match'] = all(sha(ROOT/name) == digest for name, digest in hashes.items())
        if not report['source_hashes_match']:
            raise RuntimeError('Display sources changed while testing; frozen results retained, rerun needed')
        report['passed'] = True
    except Exception as exc:
        report['error'] = str(exc)
        print(str(exc), flush=True)
    finally:
        report['completed_utc'] = datetime.now(timezone.utc).isoformat()
        (out/'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print('HDMI_V034_'+('PASS' if report['passed'] else 'FAIL'), out/'summary.json', flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
