"""Icarus-only V045 display tests/captures in an isolated source snapshot.

python tests/display_modes_v045/run_tests.py [--quick] [--workers 3]
No Gowin/synthesis/programming. All test outputs stay under this directory.
The literal oracle below is independent of generated text rows and DUT internals.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TOOL = Path('D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
sys.path.insert(0, str(HERE/'tool_deps'))
OWNED = ['src/hdmi_live_display.v', 'src/hdmi_compact_dashboard.v', 'src/hdmi_compact_text.vh',
         'src/ui_font.hex', 'assets/ui_font_map.json', 'assets/ui_texts_v045.json',
         'scripts/generate_v045_display_text.py']
DISPLAY = ['src/hdmi_live_display.v', 'src/hdmi_compact_dashboard.v', 'src/piano_roll_renderer.v',
           'src/piano_roll_score.v', 'src/piano_builtin_score_ram.v', 'src/custom_score_ram.v',
           'src/hdmi_ui_font.v', 'src/hdmi_status_cdc.v', 'src/hdmi_instrument_dashboard.v',
           'src/wave_scope.v', 'src/video_timing.v', 'src/audio_visual_renderer.v',
           'src/audio_visual_buffers.v', 'src/audio_fft512.v']
FIELDS = [('page', 2), ('mode', 2), ('waiting', 1), ('active', 1), ('done', 1),
          ('owned', 1), ('song', 2), ('strum', 2), ('cursor', 2)]
BG, TEXT, CYAN, AMBER, GREEN = 0x0b101c, 0xe2e8f0, 0x51d6e8, 0xf4bb4f, 0x21c6a8


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def scenarios():
    base = dict(page=0, mode=0, waiting=0, active=1, done=0, owned=0, song=0, strum=0, cursor=0)
    scenes = []
    def add(name, **kw):
        scenes.append(base | kw | dict(name=name, id=len(scenes)))
    add('live_fixed')
    add('live_auto', mode=1, song=1, strum=1)
    add('live_wait', mode=2, waiting=1, song=2, strum=2)
    add('practice_playing', mode=2, song=1)
    add('practice_pause', mode=2, waiting=1, active=0, song=1)
    add('practice_done', mode=2, waiting=1, done=1, song=2)
    add('fixed_ignores_wait', waiting=1)
    add('auto_ignores_wait', mode=1, waiting=1, song=1)
    for song in range(4):
        add(f'library_{song}', page=1, mode=song % 3, song=song, cursor=song, strum=song % 3)
    add('visualization', page=2, mode=2, waiting=1, song=2, strum=2)
    add('diagnostic', page=3, mode=2, waiting=1, song=2, strum=2)
    for page in range(4):
        add(f'owned_page_{page}', page=page, owned=1, mode=2, waiting=1, strum=2)
    return scenes


def labels(s):
    result = []
    def add(x, y, text, ink=TEXT):
        result.append((x, y, text, ink))
    titles = ['V045 演奏', 'V045 曲库', 'V045 可视化', 'V045 多维诊断']
    add(32, 16, 'V045 32路验证' if s['owned'] else titles[s['page']], CYAN)
    add(320, 16, ['MODE KEYBOARD', 'MODE STRUM', 'MODE HYBRID'][s['strum']], CYAN)
    if s['owned']:
        add(32, 432, '1路数 2逐路 3退出 4全32')
        add(320, 432, '0=释放 1=按下')
        add(32, 464, '0=释放 1=按下')
        add(32, 80, 'GATE 0x00000001', GREEN)
        add(320, 80, 'BUSY 0x80000001', GREEN)
        return result
    add(32, 432, '1短切页 长音色')
    add(320, 432, '2短开始/暂停 长KEY/STRUM/HYBRID')
    add(32, 464, '3短重播 长进入验证')
    add(320, 464, '4短选曲 长固定>自动>逐音')
    mode = ['固定BPM', '自动演奏', '逐音练习'][s['mode']]
    waiting = s['mode'] == 2 and s['waiting'] and s['active'] and not s['done']
    state = '完成    ' if s['done'] else ('暂停    ' if not s['active'] else ('等待按键' if waiting else '演奏    '))
    bpm = ['120', '112', '100', '---'][s['song']]
    state += ' '+bpm+' BPM'
    names = ['01 小星星', '02 灯阶练习曲', '03 溪桥练习曲']
    if s['page'] == 0:
        add(320, 80, mode)
        add(32, 112, names[s['song']])
        add(320, 112, state, AMBER if waiting else TEXT)
    else:
        add(32, 400, mode)
        add(320, 400, state, AMBER if waiting else TEXT)
        if s['page'] == 1:
            for song in range(3):
                add(32, 80+32*song, names[song], AMBER if s['cursor'] == song else TEXT)
                add(320, 80+32*song, ['120 BPM', '原创 112 BPM', '原创 100 BPM'][song])
            add(32, 272, '4长:固定BPM>自动>逐音>固定BPM')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--quick', action='store_true', help='literal pixels + CDC, no whole-frame captures')
    parser.add_argument('--workers', type=int, default=3)
    parser.add_argument('--reuse-cdc', type=Path, help='reuse passed CDC logs from an identical source snapshot')
    args = parser.parse_args()
    out = HERE/'results'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    snap = out/'snapshot'
    snap.mkdir(parents=True)
    for p in (ROOT/'src').iterdir():
        if p.is_file():
            dest = snap/'src'/p.name;dest.parent.mkdir(exist_ok=True);shutil.copy2(p, dest)
    for rel in ['tests/tb_compact_dashboard.v', 'tests/tb_v035_display_cdc.v',
                'tests/display_modes_v045/tb_display_cdc.v', 'tests/display_modes_v045/tb_display_pixels.v']:
        dest = snap/rel;dest.parent.mkdir(parents=True, exist_ok=True);shutil.copy2(ROOT/rel, dest)
    golden = (HERE/'baseline/hdmi_compact_dashboard.v.txt').read_text(encoding='utf-8')
    (snap/'golden.v').write_text(golden.replace('module hdmi_compact_dashboard #(',
        'module hdmi_compact_dashboard_golden #('), encoding='utf-8')
    env = dict(os.environ, PATH=str(TOOL)+os.pathsep+os.environ.get('PATH', ''), PYTHONIOENCODING='utf-8')
    report = dict(passed=False, source_sha256={p: sha(ROOT/p) for p in OWNED}, tests=[],
                  snapshots={p.name: sha(p) for p in (snap/'src').iterdir()},
                  gowin_run=False, synthesis_run=False, flashed=False, physical_hdmi_verified=False)
    def execute(name, argv, cwd=snap, marker=None):
        started = time.monotonic()
        p = subprocess.run(list(map(str, argv)), cwd=cwd, env=env, capture_output=True,
                           text=True, encoding='utf-8', errors='replace', timeout=900)
        log = p.stdout+p.stderr
        (out/(name+'.log')).write_text(log, encoding='utf-8')
        ok = p.returncode == 0 and 'FATAL:' not in log and (not marker or marker in log)
        rec = dict(name=name, passed=ok, seconds=round(time.monotonic()-started, 3),
                   markers=[l for l in log.splitlines() if '_PASS' in l], log=name+'.log')
        report['tests'].append(rec)
        print(name, 'PASS' if ok else 'FAIL', flush=True)
        assert ok, name+'\n'+log[-4000:]
        return rec
    def compile_tb(name, top, sources):
        exe = out/(name+'.vvp')
        execute(name+'_compile', [TOOL/'iverilog.exe', '-g2012', '-Wall', '-I', '.',
            '-s', top, '-o', exe, *sources])
        return exe
    try:
        # Baseline font safety: all legacy-used code points and pixels retained.
        mapping = json.loads((ROOT/'assets/ui_font_map.json').read_text(encoding='utf-8'))['hanzi']
        previous_map = json.loads((HERE/'baseline/ui_font_map.json').read_text(encoding='utf-8'))['hanzi']
        rom = bytes(int(v,16) for v in (snap/'src/ui_font.hex').read_text().split())
        previous_rom = bytes(int(v,16) for v in (HERE/'baseline/ui_font.hex').read_text().split())
        texts = json.loads((ROOT/'assets/ui_texts.json').read_text(encoding='utf-8'))['texts']
        needed = {c for t in texts for c in t['text'] if ord(c)>=128}
        assert len(rom)==8192 and rom[:2048]==previous_rom[:2048]
        for c in needed:
            assert mapping[c]==previous_map[c], c
            for code in mapping[c]:
                assert rom[code*16:(code+1)*16]==previous_rom[code*16:(code+1)*16], c
        report['font_validation'] = dict(legacy_used_glyphs=len(needed), ascii_unchanged=True,
                                         font_bytes=8192, character_rom_words=4096)
        for script in ['generate_v045_display_text.py', 'generate_ui_text.py', 'generate_ui_lookup.py', 'generate_v036_font.py']:
            execute(script[:-3], [sys.executable, ROOT/'scripts'/script, '--check'], cwd=ROOT, marker='_PASS')
        scenes = scenarios()
        (out/'scenes.json').write_text(json.dumps(scenes, indent=2), encoding='utf-8')
        packed=[]
        for s in scenes:
            v=0
            for key, width in FIELDS:v=(v<<width)|s[key]
            packed.append(f'{v:04x}')
        scenario_file=out/'scenarios.hex';scenario_file.write_text('\n'.join(packed)+'\n', encoding='ascii')
        # Literal Unicode -> existing glyph bitmap, independent of RTL row IDs.
        vectors=[];max_cells=0
        for s in scenes:
            for xx, yy, literal, ink in labels(s):
                cells=[]
                for char in literal:cells.extend([ord(char)] if ord(char)<128 else mapping[char])
                max_cells=max(max_cells,len(cells));assert len(cells)<=32,(literal,len(cells))
                cells += [32]*(32-len(cells))
                for row in range(16):
                    for cell, code in enumerate(cells):
                        byte=rom[code*16+row]
                        for col in range(8):
                            color=ink if byte&(1<<(7-col)) else BG
                            vectors.append(f'{xx+8*cell+col} {yy+row} 1 {s["id"]} {color:06x}\n')
            for xx,yy in [(640,0),(799,479),(0,480),(640,524),(1023,1023)]:
                vectors.append(f'{xx} {yy} 1 {s["id"]} 000000\n')
            vectors.append(f'40 30 0 {s["id"]} 000000\n')
        random.Random(45045).shuffle(vectors)
        vector_file=out/'literal_pixels.txt';vector_file.write_text(''.join(vectors),encoding='ascii')
        report['literal_oracle'] = dict(vectors=len(vectors), scenarios=len(scenes), max_cells=max_cells,
                                        source='independent literal strings in run_tests.py')
        pixels=compile_tb('pixels','tb_display_pixels',DISPLAY+['golden.v','tests/display_modes_v045/tb_display_pixels.v'])
        common=[TOOL/'vvp.exe',pixels,f'+SCENARIOS={scenario_file.as_posix()}',f'+COUNT={len(scenes)}']
        tasks=[('pixels',common+[f'+VECTORS={vector_file.as_posix()}'],'V045_PIXELS_PASS')]
        previous_report=json.loads((args.reuse_cdc/'report.json').read_text(encoding='utf-8')) if args.reuse_cdc else None
        if previous_report:
            assert previous_report['source_sha256']==report['source_sha256'], 'Cached CDC owned sources differ'
            for rel in DISPLAY+['src/piano_song_rom_v045.vh','src/piano_builtin_score.hex',
                                'tests/display_modes_v045/tb_display_cdc.v','tests/tb_v035_display_cdc.v']:
                assert sha(args.reuse_cdc/'snapshot'/rel)==sha(snap/rel), 'Cached CDC differs: '+rel
        for name,top,bench,marker in [('cdc','tb_display_cdc','tests/display_modes_v045/tb_display_cdc.v','V045_CDC_PASS'),
                                     ('legacy_cdc','tb_v035_display_cdc','tests/tb_v035_display_cdc.v','V035_DISPLAY_CDC_PASS')]:
            cached=next((r for r in previous_report['tests'] if r['name']==name and r['passed']),None) if previous_report else None
            if cached:
                shutil.copy2(args.reuse_cdc/cached['log'],out/cached['log'])
                report['tests'].append(cached | dict(reused_from=str(args.reuse_cdc)))
                print(name,'PASS (identical-source cached run)',flush=True)
            else:
                exe=compile_tb(name,top,DISPLAY+['tests/tb_compact_dashboard.v',bench])
                tasks.append((name,[TOOL/'vvp.exe',exe],marker))
        captures=[0,1,2,9] if not args.quick else []
        for s in captures:
            tasks.append((scenes[s]['name'],common+[f'+SCENE={s}',f'+PPM={(out/(scenes[s]["name"]+".ppm")).as_posix()}'],
                          'V045_CAPTURE_PASS'))
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures=[pool.submit(execute,name,argv,marker=marker) for name,argv,marker in tasks]
            for f in futures:f.result()
        if captures:
            from PIL import Image,ImageDraw
            sheet=Image.new('RGB',(1280,((len(captures)+1)//2)*512),(11,16,28));draw=ImageDraw.Draw(sheet)
            for n,s in enumerate(captures):
                name=scenes[s]['name']
                im=Image.open(out/(name+'.ppm')).convert('RGB');assert im.size==(640,480)
                im.save(out/(name+'.png'))
                xx=(n%2)*640;yy=(n//2)*512
                draw.text((xx+12,yy+8),name,fill=(226,232,240));sheet.paste(im,(xx,yy+32))
            sheet.save(out/'preview_contact_sheet.png')
            report['preview']='preview_contact_sheet.png'
        assert report['source_sha256']=={p:sha(ROOT/p) for p in OWNED}, 'Owned files changed during run'
        # Other agents own top/guide/ESP: unrelated edits do not stale this
        # display snapshot. Follow only the compiled sources' local assets.
        dependencies=set(DISPLAY);pending=list(DISPLAY)
        while pending:
            rel=pending.pop()
            if not rel.endswith(('.v','.vh')):continue
            content=(snap/rel).read_text(encoding='utf-8')
            for ref in re.findall(r'"(src/[^"\r\n]+)"',content):
                if (snap/ref).is_file() and ref not in dependencies:
                    dependencies.add(ref);pending.append(ref)
        drift=[rel for rel in dependencies if sha(ROOT/rel)!=sha(snap/rel)]
        report['dependency_changes_during_run']=drift
        assert not drift, 'Dependencies changed during snapshot run; rerun: '+str(drift)
        report['passed']=True
    except Exception:
        report['error']=traceback.format_exc()
        print(report['error'],flush=True)
    finally:
        (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        latest=dict(report_path=str(out/'report.json'),**report)
        (HERE/'latest_report.json').write_text(json.dumps(latest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        print('V045_DISPLAY_PASS' if report['passed'] else 'V045_DISPLAY_FAIL',out,flush=True)
    return 0 if report['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
