"""Offline pixel/CDC checks and real RTL 640x480 PPM -> Pillow PNG previews.

Run: python scripts/run_piano_roll_render_tests.py
Parameters: hdmi_live_display.PIANO_ROLL_ENABLE=1 (implies compact), renderer
two stages; RAM raster + renderer + RGB output = four wrapper stages. Feature0
preserves 242/252/289-bit packets; feature1 appends49 bits, total338.
No board, serial port, flash, audio changes, image generation or publishing.
"""
from pathlib import Path
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from toolchain import find_icarus, ToolchainError

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    'src/hdmi_compact_dashboard.v', 'src/piano_roll_renderer.v',
    'src/piano_roll_score.v', 'src/hdmi_ui_font.v', 'src/hdmi_live_display.v',
    'src/hdmi_status_cdc.v', 'src/hdmi_instrument_dashboard.v',
    'src/wave_scope.v', 'src/video_timing.v',
]
BENCHES = ['tests/tb_piano_roll_pixels.v', 'tests/tb_piano_roll_cdc.v',
           'tests/tb_compact_dashboard.v']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-previews', action='store_true')
    parser.add_argument('--pillow-python', type=Path,
        default=Path(sys.executable), help='Python with Pillow; defaults to the current interpreter')
    args = parser.parse_args()
    try:
        tools = find_icarus()
    except ToolchainError as exc:
        parser.error(str(exc))
    out = ROOT/'tests/piano_roll_artifacts'
    out.mkdir(exist_ok=True)
    snap = out/'input'
    (snap/'src').mkdir(parents=True, exist_ok=True)
    (snap/'tests').mkdir(exist_ok=True)
    inputs = [ROOT/s for s in SOURCES+BENCHES]
    inputs += list((ROOT/'src').glob('*.vh')) + list((ROOT/'src').glob('*.hex'))
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    for p in inputs:
        shutil.copy2(p, snap/p.relative_to(ROOT))
    env = tools.environment()
    records = []

    def run(name, argv, marker=None):
        start = time.monotonic()
        p = subprocess.run(list(map(str, argv)), cwd=snap, env=env,
                           capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
        (out/(name+'.log')).write_text(p.stdout+p.stderr, encoding='utf-8')
        rec = dict(name=name, argv=list(map(str, argv)), exit=p.returncode,
                   elapsed_seconds=round(time.monotonic()-start, 3),
                   passed=p.returncode==0 and 'FATAL:' not in p.stdout+p.stderr and (not marker or marker in p.stdout))
        records.append(rec)
        print(name, 'PASS' if rec['passed'] else 'FAIL', rec['elapsed_seconds'], flush=True)
        if not rec['passed']:
            print(p.stdout+p.stderr, flush=True)
            raise RuntimeError(name)

    def compile_bench(top, bench, extra=()):
        executable = out/(top+'.vvp')
        run(top+'_compile', [tools.iverilog, '-g2012', '-Wall', '-I', '.', '-s', top,
            '-o', executable, *SOURCES, bench, *extra])
        return executable

    report = {'source_hashes': before, 'tools': tools.as_dict(),
              'pillow_python': str(args.pillow_python), 'parameters': {'PIANO_ROLL_ENABLE': 1},
              'pipeline': {'renderer_stages': 2, 'wrapper_stages': 4},
              'packet_widths': [242,252,289,338],
              'geometry': {'white_keys':19,'black_keys':13,'midi_range':[41,72],
                           'white_width':30,'black_width':18,'bar_width':12,
                           'x':[35,604],'roll_y':[144,319],'hit_y':[320,323],
                           'keyboard_y':[324,399],'black_end_y':369,
                           'footer_text_y':[416,448], 'ticks_per_beat':64,
                           'pixels_per_tick':1,'bpm':120,'countin_beats':2},
              'cases': records, 'previews': [], 'hardware_programmed':False,
              'physical_validation':False, 'synthesis_run':False}
    try:
        pixels = compile_bench('tb_piano_roll_pixels', 'tests/tb_piano_roll_pixels.v')
        cdc = compile_bench('tb_piano_roll_cdc', 'tests/tb_piano_roll_cdc.v', ['tests/tb_compact_dashboard.v'])
        with ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [pool.submit(run, 'pixels', [tools.vvp,pixels], 'PIANO_ROLL_PIXELS_PASS'),
                    pool.submit(run, 'cdc', [tools.vvp,cdc], 'PIANO_ROLL_CDC_PASS')]
            for job in jobs:
                job.result()
        if not args.no_previews:
            scenes = ['live_play', 'live_16ticks_later', 'paused_held_outside',
                      'diagnostic_pcm', 'oscillator32', 'library', 'help']
            def render_scene(scene, name):
                ppm = out/(name+'.ppm')
                run('render_'+name, [tools.vvp,pixels,'+CAPTURE_ONLY',f'+SCENE={scene}',f'+PPM={ppm.as_posix()}'], 'PIANO_ROLL_PREVIEW_PASS')
                png = ppm.with_suffix('.png')
                code = ('from PIL import Image; import sys; '
                        'im=Image.open(sys.argv[1]); assert im.size==(640,480); '
                        'im.save(sys.argv[2])')
                run('png_'+name,[args.pillow_python,'-c',code,ppm,png])
                return str(png.relative_to(ROOT))
            with ThreadPoolExecutor(max_workers=2) as pool:
                jobs=[pool.submit(render_scene, scene, name) for scene,name in enumerate(scenes)]
                report['previews']=[job.result() for job in jobs]
        report['source_hashes_match'] = all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in before.items())
        if not report['source_hashes_match']:
            raise RuntimeError('Sources changed while testing; frozen snapshot results retained, rerun required')
        report['passed'] = True
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('PIANO_ROLL_RENDER_REGRESSION_PASS',out,flush=True)


if __name__ == '__main__':
    main()
