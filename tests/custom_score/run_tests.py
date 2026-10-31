"""Frozen RTL regression and optional isolated Gowin resource A/B.

Run from anywhere: python tests/custom_score/run_tests.py [--synth] [--workers 4]
Writes ONLY under tests/custom_score/artifacts. Never builds the production
project, modifies top/controller/constraints, releases firmware or uses hardware.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
TOOL = Path('D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
GOWIN = Path('D:/Gowin_V1.9.12.04_x64_win/Gowin/Gowin_V1.9.12.04_x64/IDE/bin/gw_sh.exe')
OWNED = ['src/piano_roll_guide.v', 'src/piano_roll_renderer.v',
         'src/hdmi_compact_dashboard.v', 'src/hdmi_live_display.v', 'src/custom_score_ram.v']
DISPLAY = ['src/hdmi_live_display.v', 'src/hdmi_compact_dashboard.v',
           'src/piano_roll_renderer.v', 'src/piano_roll_score.v', 'src/custom_score_ram.v',
           'src/hdmi_ui_font.v', 'src/hdmi_status_cdc.v', 'src/hdmi_instrument_dashboard.v',
           'src/wave_scope.v', 'src/video_timing.v', 'src/audio_visual_renderer.v',
           'src/audio_visual_buffers.v', 'src/audio_fft512.v']
GUIDE = ['src/piano_roll_guide.v', 'src/piano_roll_score.v', 'src/custom_score_ram.v']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(base):
    return {p.relative_to(base).as_posix(): sha(p) for p in sorted((base/'src').rglob('*')) if p.is_file()} | {
        p.name: sha(p) for p in sorted(base.glob('*.gprj'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth', action='store_true')
    parser.add_argument('--synth-only', action='store_true')
    parser.add_argument('--yosys', action='store_true',help='optional experimental Gowin mapping A/B; no vendor license needed')
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--case',action='append',help='run only named simulation case(s), repeatable')
    args = parser.parse_args()
    out = ROOT/'tests/custom_score/artifacts'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    snap = out/'snapshot'
    snap.mkdir(parents=True)
    for folder in ['src', 'tests']:
        for p in (ROOT/folder).rglob('*'):
            if any(n in p.parts for n in ['artifacts','piano_roll_artifacts','smoke','tool_deps']):
                continue
            if p.is_file() and p.suffix in ['.v', '.vh', '.hex']:
                dest = snap/p.relative_to(ROOT)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, dest)
    hashes = {p: sha(ROOT/p) for p in OWNED}
    golden=snap/'tests/custom_score/builtin_golden.v'
    golden.write_text((ROOT/'tests/custom_score/baseline_piano_roll_guide.v.txt').read_text(
        encoding='utf-8').replace('module piano_roll_guide #(', 'module piano_roll_guide_baseline #('),encoding='utf-8')
    (snap/'tests/custom_score/renderer_golden.v').write_text((ROOT/'tests/custom_score/baseline_piano_roll_renderer.v.txt').read_text(
        encoding='utf-8').replace('module piano_roll_renderer(', 'module piano_roll_renderer_baseline('),encoding='utf-8')
    report = dict(passed=False, owned_sha256=hashes, tests=[], synthesis=[],
                  hardware_tested=False, flashed=False, production_project_built=False,
                  renderer_stages=2, wrapper_stages=4)
    env = dict(os.environ, PATH=str(TOOL)+os.pathsep+os.environ.get('PATH', ''))

    def execute(label, argv, cwd=snap, timeout=180, marker=None):
        started = time.monotonic()
        try:
            proc = subprocess.run(list(map(str, argv)), cwd=cwd, env=env, capture_output=True,
                                  text=True, encoding='utf-8', errors='replace', timeout=timeout)
            log = proc.stdout+proc.stderr
            code=proc.returncode
        except subprocess.TimeoutExpired as exc:
            def decoded(value):return value.decode('utf-8',errors='replace') if isinstance(value,bytes) else value or ''
            log=decoded(exc.stdout)+decoded(exc.stderr)+f'\nTIMEOUT after {timeout}s\n'
            code=None
        (out/(label+'.log')).write_text(log, encoding='utf-8')
        return dict(argv=list(map(str, argv)), cwd=str(cwd), exit=code,
                    seconds=round(time.monotonic()-started, 3), log=label+'.log',
                    metrics=[line for line in log.splitlines() if '_PASS' in line],
                    passed=code==0 and 'FATAL:' not in log and
                           (marker is None or marker in log))

    def test(case):
        label, top, sources, params, marker = case
        executable = out/(label+'.vvp')
        compile_result = execute(label+'_compile', [TOOL/'iverilog.exe','-g2012','-Wall',
            '-I','.', '-s',top, *params, '-o',executable, *sources])
        rec = dict(name=label, compile=compile_result, passed=False)
        if compile_result['passed']:
            rec['run'] = execute(label, [TOOL/'vvp.exe',executable], marker=marker)
            rec['passed'] = rec['run']['passed']
        print(label, 'PASS' if rec['passed'] else 'FAIL', flush=True)
        if not rec['passed']:
            print((out/(rec.get('run',compile_result)['log'])).read_text(encoding='utf-8')[-3000:], flush=True)
        return rec

    try:
        if not args.synth_only:
            cases=[]
            cases.append(('enabled_builtin_compat','tb_custom_builtin_compat',GUIDE+[
                'src/piano_roll_renderer.v','tests/custom_score/tb_custom_builtin_compat.v',
                'tests/custom_score/builtin_golden.v','tests/custom_score/renderer_golden.v'],
                [],'CUSTOM_BUILTIN_COMPAT_PASS'))
            for beat in [0,1,7,63,64,65,67,1001,46875]:
                cases.append((f'legacy_guide_{beat}','tb_piano_roll_guide',
                    GUIDE+['tests/tb_piano_roll_guide.v'],
                    [f'-Ptb_piano_roll_guide.TEST_BEAT_SAMPLES={beat}'],'PIANO_ROLL_GUIDE_TEST_PASS'))
            for spb in [23437,46875,93750,187500]:
                cases.append((f'custom_guide_{spb}','tb_custom_score_guide',
                    GUIDE+['tests/custom_score/tb_custom_score_guide.v'],
                    [f'-Ptb_custom_score_guide.SPB={spb}'],'CUSTOM_GUIDE_PASS'))
            for phase in [0,3,11,19]:
                cases.append((f'custom_pixels_phase{phase}','tb_custom_score_pixels',
                    ['src/piano_roll_renderer.v','src/piano_roll_score.v','src/custom_score_ram.v',
                     'tests/custom_score/tb_custom_score_pixels.v'],
                    [f'-Ptb_custom_score_pixels.PIXEL_PHASE={phase}'],'CUSTOM_PIXELS_PASS'))
            for top,marker in [('tb_piano_roll_pixels','PIANO_ROLL_PIXELS_PASS'),
                               ('tb_piano_roll_cdc','PIANO_ROLL_CDC_PASS'),
                               ('tb_hdmi_hybrid_cdc','HDMI_HYBRID_CDC_PASS'),
                               ('tb_audio_visual_renderer','AUDIO_VISUAL_RENDERER_PASS')]:
                sources=DISPLAY+['tests/'+top+'.v']
                if 'cdc' in top:sources+=['tests/tb_compact_dashboard.v']
                cases.append((top,top,sources,[],marker))
            cases.append(('custom_display','tb_custom_score_display',
                DISPLAY+['src/piano_roll_guide.v','tests/custom_score/tb_custom_score_display.v',
                         'tests/tb_compact_dashboard.v'],[],'CUSTOM_DISPLAY_PASS'))
            if args.case:
                unknown=set(args.case)-{c[0] for c in cases}
                if unknown:raise ValueError('Unknown cases: '+','.join(sorted(unknown)))
                cases=[c for c in cases if c[0] in args.case]
            with ThreadPoolExecutor(max_workers=args.workers) as pool:
                report['tests']=list(pool.map(test,cases))
        if args.synth or args.synth_only or args.yosys:
            files=GUIDE+['src/piano_roll_renderer.v','tests/custom_score/resource_top.v','src/piano_layout.vh']
            for enable in [0,1]:
                work=out/f'synth_{enable}'
                for name in files:
                    dest=work/name;dest.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copy2(snap/name,dest)
                project=ET.Element('Project')
                ET.SubElement(project,'Template').text='FPGA'
                ET.SubElement(project,'Version').text='5'
                ET.SubElement(project,'Device',name='GW2A-18C',pn='GW2A-LV18PG256C8/I7').text='gw2a18c-011'
                listing=ET.SubElement(project,'FileList')
                for name in files:
                    if name.endswith('.v'):ET.SubElement(listing,'File',path=name,type='file.verilog',enable='1')
                ET.ElementTree(project).write(work/'resource.gprj',encoding='utf-8',xml_declaration=True)
                (work/'synth.tcl').write_text('cd [file dirname [file normalize [info script]]]\n'
                    'open_project resource.gprj\nset_option -top_module custom_score_resource_core\n'
                    'set_option -verilog_std v2001\n'
                    'run syn\nexit\n',encoding='utf-8')
                # A/B is elaborated in the frozen test harness only.
                harness=work/'tests/custom_score/resource_top.v'
                harness.write_text(harness.read_text(encoding='utf-8').replace('parameter ENABLE=1',f'parameter ENABLE={enable}'),encoding='utf-8')
                rec=execute(f'synth_{enable}',[GOWIN,'synth.tcl'],cwd=work,timeout=300)
                rec['enable']=enable
                rec['resource_files']=[str(p.relative_to(out)) for p in work.rglob('*')
                                       if p.is_file() and ('rsc' in p.name or p.suffix in ['.v','.vg']) and 'impl' in p.parts]
                report['synthesis'].append(rec)
                print(f'synth_{enable}', 'PASS' if rec['passed'] else 'FAIL',flush=True)
                if not rec['passed']:print((out/rec['log']).read_text(encoding='utf-8')[-4000:],flush=True)
                if args.yosys:
                    # The Verilog frontend in Wasm is very slow at expanding
                    # the existing 1024x18 nested geometry initial loop. Dump
                    # the ACTUAL frozen RTL ROM with Icarus and read the same
                    # 1024 words for mapping; no geometry is re-created by a
                    # Python oracle or changed in the production source.
                    (work/'dump_geometry.v').write_text('`timescale 1ns/1ps\nmodule dump_geometry;\n'
                        'piano_roll_renderer dut();\ninitial begin #1;'
                        '$writememh("geometry.hex",dut.geometry);$finish;end\nendmodule\n',encoding='utf-8')
                    gc=execute(f'geometry_compile_{enable}',[TOOL/'iverilog.exe','-g2012','-I','.',
                        '-s','dump_geometry','-o','geometry.vvp',
                        *[n for n in files if n.endswith('.v')],'dump_geometry.v'],cwd=work)
                    gr=execute(f'geometry_dump_{enable}',[TOOL/'vvp.exe','geometry.vvp'],cwd=work)
                    if not (gc['passed'] and gr['passed']):raise RuntimeError('geometry dump failed')
                    renderer=work/'src/piano_roll_renderer.v'
                    rtl=renderer.read_text(encoding='utf-8')
                    first=rtl.index('    initial begin\n')
                    last=rtl.index('    wire [8:0] ahead=',first)
                    renderer.write_text(rtl[:first]+'    initial $readmemh("geometry.hex",geometry);\n'+rtl[last:],encoding='utf-8')
                    (work/'check.ys').write_text('read_verilog -I. '+' '.join(n for n in files if n.endswith('.v'))+'\n'
                        'hierarchy -check -top custom_score_resource_core\nproc\nopt\nmemory_collect\n'
                        'write_json before_mapping.json\n'
                        'synth_gowin -top custom_score_resource_core -family gw2a -noiopads -nowidelut -no-rw-check\n'
                        'write_json mapped.json\nstat\n',encoding='utf-8')
                    yr=execute(f'yosys_{enable}',[sys.executable,ROOT/'tests/custom_score/yosys_driver.py',
                        '-Q','-T','-s','check.ys'],cwd=work,timeout=300)
                    yr['enable']=enable;yr['experimental_mapping']=True
                    yr['geometry_dump_from_frozen_rtl']=dict(compile=gc,run=gr,
                        hex_sha256=sha(work/'geometry.hex'),words=1024)
                    if yr['passed']:
                        mapped=json.loads((work/'mapped.json').read_text(encoding='utf-8'))
                        cells=mapped['modules']['custom_score_resource_core']['cells']
                        counts={}
                        for c in cells.values():counts[c['type']]=counts.get(c['type'],0)+1
                        yr['cell_counts']=counts
                        before=json.loads((work/'before_mapping.json').read_text(encoding='utf-8'))
                        kinds=[c['type'] for mod in before['modules'].values() for c in mod.get('cells',{}).values()]
                        yr['runtime_div_mod_cells']=sum(k in ['$div','$mod','$divfloor','$modfloor'] for k in kinds)
                    report['synthesis'].append(yr)
                    print(f'yosys_{enable}', 'PASS' if yr['passed'] else 'FAIL',flush=True)
                    if not yr['passed']:print((out/yr['log']).read_text(encoding='utf-8')[-3000:],flush=True)
        baseline=json.loads((ROOT/'tests/custom_score/baseline.json').read_text(encoding='utf-8'))
        observed=manifest(ROOT)
        report['isolated_changes_since_baseline']=[p for p,h in observed.items() if baseline['isolated'].get(p)!=h]
        report['original_unchanged']=manifest(Path(baseline['original_path']))==baseline['original']
        report['owned_stable']=hashes=={p:sha(ROOT/p) for p in OWNED}
        report['passed']=all(r['passed'] for r in report['tests']+report['synthesis']) and report['original_unchanged'] and report['owned_stable']
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
        (ROOT/'tests/custom_score/latest_report.txt').write_text(str(out/'summary.json')+'\n',encoding='utf-8')
        print('REPORT',out/'summary.json',flush=True)
    return 0 if report['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
