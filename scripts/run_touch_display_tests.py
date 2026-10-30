"""触摸显示专用离线回归；只用Icarus，不综合、不烧录、不访问串口。

复制被测输入到独立临时目录并记录SHA256；所有日志/逐像素oracle/预览均留在该目录。
默认不向共享工程写验证文件。可用 --output 指定独立输出目录的父路径。
原文案生成器--check、旧查找表和旧252/242位CDC照常执行，不改冻结参考。
COMPACT生产布局的截图预期见menu_layout.json.compact.oracle_replacement。
全部16触摸键不产生NoteOn需主agent的top/input/audio集成测试，本脚本不作该声明。
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    'src/touch_display_control.v', 'src/oscillator_test_control.v',
    'src/hdmi_compact_dashboard.v', 'src/hdmi_live_display.v', 'src/hdmi_status_cdc.v',
    'src/hdmi_instrument_dashboard.v', 'src/hdmi_ui_font.v', 'src/ui_font.hex',
    'src/hdmi_ui_text.vh', 'src/hdmi_ui_lookup.vh', 'src/video_timing.v', 'src/wave_scope.v',
    'assets/ui_texts.json', 'assets/ui_font_map.json', 'assets/menu_layout.json',
    'tests/tb_touch_display_control.v', 'tests/tb_compact_dashboard.v',
    'tests/tb_ui_lookup_equivalence.v', 'tests/tb_menu_cdc.v', 'tests/tb_hdmi_live_display.v',
    'scripts/generate_ui_text.py', 'scripts/generate_ui_lookup.py', 'scripts/run_touch_display_tests.py',
]
DISPLAY = ['src/hdmi_compact_dashboard.v', 'src/hdmi_ui_font.v',
           'src/hdmi_instrument_dashboard.v', 'src/hdmi_live_display.v',
           'src/hdmi_status_cdc.v', 'src/video_timing.v', 'src/wave_scope.v']
SIGNALS = 'ui_page ui_cursor ui_song control_page fx_mode strum_mode knob_values keys ui_controls timbre note note_valid frequency_bcd volume_percent level_dbfs peak_percent voices flags cue_mask next_mask wrong_mask guide_step guide_total wave_current wave_previous scope_gain wave_valid test_active test_requested test_busy test_gate test_sweep test_index test_overrun'.split()
PALETTE = dict(BG=0x0b101c, PANEL=0x172338, BORDER=0x34465f, GRID=0x22324a,
               TEXT=0xe2e8f0, CYAN=0x51d6e8, GREEN=0x21c6a8, AMBER=0xf4bb4f, ALERT=0xff5964)
FAILURE = re.compile(r'(?im)^\s*(?:ERROR:|FATAL:)')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(argv, cwd, timeout):
    started = time.monotonic()
    record = dict(argv=list(map(str, argv)))
    try:
        proc = subprocess.run(record['argv'], cwd=cwd, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=timeout)
        record.update(returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
    except (OSError, subprocess.TimeoutExpired) as exc:
        record.update(returncode=None, error=str(exc))
    record['elapsed_seconds'] = round(time.monotonic()-started, 3)
    return record


def oracle(snapshot, link_only=False):
    """独立字符编码/波形数学模型；完全不读取或解释任何RTL函数。"""
    layout = json.loads((snapshot/'assets/menu_layout.json').read_text(encoding='utf-8'))['compact']
    mapping = json.loads((snapshot/'assets/ui_font_map.json').read_text(encoding='utf-8'))['hanzi']
    font = [int(v, 16) for v in (snapshot/'src/ui_font.hex').read_text().split()]
    assert len(font) == 8192 and max(v for pair in mapping.values() for v in pair) == 511
    geom = layout['text_regions']
    records = []
    for index, scene in enumerate(layout['oracle_scenes']):
        if link_only and index>0: break
        status = scene['status']
        image = bytearray(PALETTE['BG'].to_bytes(3, 'big')*(640*480))

        def pixel(x, y, color):
            offset = (y*640+x)*3
            image[offset:offset+3] = color.to_bytes(3, 'big')

        if status['test_active'] or status['ui_page'] == 0:
            def wave_y(sample):
                scaled = (sample*(1 << status['scope_gain'])) >> 9
                return 212-max(-60, min(60, scaled))
            low, high = sorted((wave_y(status['wave_previous']), wave_y(status['wave_current'])))
            for y in range(143, 281):
                for x in range(31, 545):
                    color = PALETTE['BORDER']
                    if 32 <= x < 544 and 144 <= y < 280:
                        color = PALETTE['PANEL']
                        if (x-32) % 64 == 0 or y in (176, 248): color = PALETTE['GRID']
                        if y == 212: color = PALETTE['BORDER']
                        if status['wave_valid'] and low <= y <= high: color = PALETTE['CYAN']
                    pixel(x, y, color)
        for band, row in scene['rows'].items():
            y0 = geom['y_origin']+int(band)*geom['band_stride']
            for side in ('left', 'right'):
                x0 = geom[side+'_x']
                cells = []
                for char in row[side]: cells.extend([ord(char)] if ord(char) < 128 else mapping[char])
                assert len(cells) <= 32, row[side]
                for col, code in enumerate(cells):
                    for gy in range(16):
                        bits = font[code*16+gy]
                        for gx in range(8):
                            if bits & (128 >> gx): pixel(x0+col*8+gx, y0+gy, PALETTE[row[side+'_ink']])

        def vector(x, y, de, hs, vs):
            color = int.from_bytes(image[(y*640+x)*3:(y*640+x+1)*3], 'big') if de and x < 640 and y < 480 else 0
            return f'{(x << 37) | (y << 27) | (de << 26) | (hs << 25) | (vs << 24) | color:012x}\n'

        vector_path = snapshot/f'scene_{index}.vec'
        count = 0
        with vector_path.open('w', encoding='ascii') as out:
            # 全帧包括空白、文字窗边界、波形窗边框；乱序/DE插空追加检查流水。
            for y in range(0 if link_only else 480):
                out.writelines(vector(x, y, 1, 1, 1) for x in range(640)); count += 640
            for x in [0, 31, 32, 287, 288, 319, 320, 575, 576, 639, 640, 656, 751, 752, 799, 1023]:
                for y in [0, 15, 16, 31, 32, 143, 144, 152, 212, 272, 279, 280, 463, 464, 479, 480, 490, 492, 524, 1023]:
                    for de in (0, 1): out.write(vector(x, y, de, int(x < 656 or x > 751), int(y not in (490, 491)))); count += 1
            rng = random.Random(0x3208+index)
            for _ in range(4096):
                out.write(vector(rng.randrange(1024), rng.randrange(1024), rng.randrange(2), rng.randrange(2), rng.randrange(2))); count += 1
        (snapshot/f'scene_{index}.cfg').write_text(' '.join(f'{status[k] & 0xffffffff:x}' for k in SIGNALS)+'\n', encoding='ascii')
        (snapshot/f'{scene["name"]}.ppm').write_bytes(b'P6\n640 480\n255\n'+image)
        records.append(dict(scene=index, name=scene['name'], vectors=count, sha256=sha(vector_path)))
        if index == 0:
            with (snapshot/'link.vec').open('w', encoding='ascii') as out:
                for y in range(48): out.writelines(vector(x, y, 1, 1, 1) for x in range(640))
                for _ in range(2048):
                    x = rng.choice([31,32,40,287,288,319,320,575,576,639,640,656,751,752,799,1023])
                    y = rng.randrange(48)
                    out.write(vector(x,y,rng.randrange(2),rng.randrange(2),rng.randrange(2)))
            # 独立显式偏移，低242位仍按旧打包约定；不从RTL提取布局。
            offsets = dict(keys=230,timbre=226,note=219,note_valid=218,frequency_bcd=202,
                           volume_percent=194,level_dbfs=186,peak_percent=178,voices=163,
                           flags=139,cue_mask=125,next_mask=113,wrong_mask=101,
                           guide_step=95,guide_total=89,test_active=77,test_requested=71,
                           test_busy=39,test_gate=7,test_sweep=6,test_index=1,test_overrun=0,
                           ui_page=250,ui_cursor=248,ui_song=246,ui_controls=242,
                           control_page=287,fx_mode=285,strum_mode=284,knob_values=252)
            word = 0
            for name, offset in offsets.items():
                value = status[name] & 255 if name == 'level_dbfs' else status[name]
                word |= value << offset
            (snapshot/'link_status.hex').write_text(f'{word:073x}\n', encoding='ascii')
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--workers', type=int, default=3)
    parser.add_argument('--timeout', type=int, default=240)
    parser.add_argument('--links-only', action='store_true',
                        help='只重跑compact链接、旧252/242位CDC及旧三拍封装；不重复控制器/画面/生成器检查')
    args = parser.parse_args()
    if args.output: args.output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='touch_display_', dir=args.output))
    snapshot = run/'snapshot'; snapshot.mkdir()
    report = dict(status='fail', started_utc=datetime.now(timezone.utc).isoformat(),
                  run_directory=str(run), sources_sha256={}, tests=[], oracle=[],
                  scope='links_only' if args.links_only else 'full',
                  synthesized=False, hardware_tested=False, programmed=False,
                  limitations=['All16 touch NoteOn isolation is covered by the parent integration task.',
                               'LUT/BSRAM usage and timing are unmeasured: no synthesis was run.',
                               'PLL/TMDS boundaries are behavioral models; no physical HDMI check.'])
    started = time.monotonic()
    try:
        for name in SOURCES:
            source = ROOT/name; target = snapshot/name
            target.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(source, target)
            report['sources_sha256'][name] = sha(target)
        runtime = ROOT/'tools/vendor/iverilog-v12/app/bin'
        suffix = '.exe' if os.name == 'nt' else ''
        iverilog, vvp = runtime/('iverilog'+suffix), runtime/('vvp'+suffix)
        if not iverilog.is_file() or not vvp.is_file(): raise FileNotFoundError('Project Icarus runtime missing')
        report['runtime'] = dict(iverilog=str(iverilog), vvp=str(vvp), iverilog_sha256=sha(iverilog), vvp_sha256=sha(vvp))
        for script, marker in ([] if args.links_only else [('generate_ui_text.py','UI_TEXT_CHECK_PASS'), ('generate_ui_lookup.py','UI_LOOKUP_CHECK_PASS')]):
            record = command([sys.executable, '-B', 'scripts/'+script, '--check'], snapshot, args.timeout)
            record.update(name=script, status='pass' if record['returncode']==0 and marker in record.get('stdout','') else 'fail')
            report['tests'].append(record)
            if record['status'] != 'pass': raise RuntimeError(record)
        report['oracle'] = oracle(snapshot,link_only=args.links_only)
        # 历史bench用39个位置端口，早于四页元数据和本次新增端口。
        # 只在独立派生harness末尾补0绑定；原文件、像素参考、断言全都保持原样。
        legacy_text = (snapshot/'tests/tb_hdmi_live_display.v').read_text(encoding='utf-8')
        old_tail = 'progress,beats,clip,cp,cn,dp,dn,locked,fs,1\'b0,6\'d0,32\'d0,32\'d0,1\'b0,5\'d0,1\'b0);'
        new_tail = old_tail[:-2]+",2'd0,2'd0,2'd0,4'd0,2'd0,2'd0,1'b0,32'd0);"
        if legacy_text.count(old_tail) != 1: raise RuntimeError('Historical positional binding changed; inspect before adapting')
        bound_path = snapshot/'tests/tb_hdmi_live_display_bound.v'
        bound_path.write_text(legacy_text.replace(old_tail,new_tail),encoding='utf-8')
        report['historical_harness'] = dict(original='tests/tb_hdmi_live_display.v', derived=str(bound_path),
            description='Append zero bindings for eight previously absent UI/compact inputs only; all pixel expectations and assertions unchanged.',
            sha256=sha(bound_path))
        # 旧CDC bench只变更派生副本中的层级路径，原源文件/状态偏移/断言不变。
        menu_text = (snapshot/'tests/tb_menu_cdc.v').read_text(encoding='utf-8')
        if 'dut.u_dashboard.' not in menu_text: raise RuntimeError('Historical menu hierarchy changed; inspect binding')
        menu_bound = snapshot/'tests/tb_menu_cdc_bound.v'
        menu_bound.write_text(menu_text.replace('dut.u_dashboard.','dut.legacy_ui.u_dashboard.'),encoding='utf-8')
        report['historical_menu_harness'] = dict(original='tests/tb_menu_cdc.v',derived=str(menu_bound),
            description='Hierarchy binding only: dut.u_dashboard -> dut.legacy_ui.u_dashboard; every original assertion retained.',sha256=sha(menu_bound))
        cases = []
        for hold in ([] if args.links_only else [0,1,4,112500,200000]):
            cases.append((f'touch_hold_{hold}', 'tb_touch_display_control',
                          ['src/touch_display_control.v','src/oscillator_test_control.v','tests/tb_touch_display_control.v'],
                          [f'-Ptb_touch_display_control.TEST_HOLD={hold}'], [], 'TOUCH_DISPLAY_CONTROL_TEST_PASS'))
        # One renderer executable serves eight independent full-frame scenarios.
        if not args.links_only:
            cases.append(('compile_compact', 'tb_compact_dashboard',
                          ['src/hdmi_compact_dashboard.v','src/hdmi_ui_font.v','tests/tb_compact_dashboard.v'], [], [], None))
            cases.append(('legacy_lookup','tb_ui_lookup_equivalence',['tests/tb_ui_lookup_equivalence.v'],[],[],'UI_LOOKUP_EQUIVALENCE_TEST_PASS'))
        # 故意不给compact编译提供旧dashboard模块：能成功编译并运行，即证明
        # COMPACT_UI=1在elaboration阶段已彻底排除旧实例，而非依赖死逻辑优化。
        compact_sources = [s for s in DISPLAY if s!='src/hdmi_instrument_dashboard.v']
        report['compact_link_excludes_legacy_module_definition'] = True
        cases += [('compact_link','tb_compact_display_link',compact_sources+['tests/tb_compact_dashboard.v'],[],[],'COMPACT_DISPLAY_LINK_TEST_PASS'),
                  ('legacy_cdc','tb_menu_cdc',DISPLAY+['tests/tb_menu_cdc_bound.v'],[],[],'MENU_CDC_TEST_PASS'),
                  ('legacy_wrapper','tb_hdmi_live_display',DISPLAY+['tests/tb_compact_dashboard.v','tests/tb_hdmi_live_display_bound.v'],[],[],'HDMI_LIVE_DISPLAY_TEST_PASS')]

        def run_case(case):
            name, top, sources, parameters, plusargs, marker = case
            output = run/(name+'.vvp')
            compiled = command([iverilog,'-g2012','-Wall','-s',top,'-I',snapshot,'-o',output,*parameters,*sources], snapshot, args.timeout)
            result = dict(name=name, status='fail', compile=compiled)
            if compiled['returncode'] == 0:
                if marker is None: result['status'] = 'pass'
                else:
                    simulated = command([vvp,output,*plusargs], snapshot, args.timeout)
                    result['simulation'] = simulated
                    text = simulated.get('stdout','')+simulated.get('stderr','')
                    if simulated['returncode']==0 and marker in text and not FAILURE.search(text): result['status']='pass'
            print(f'{name}: {result["status"]}', flush=True)
            (run/(name+'.json')).write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
            return result

        with ThreadPoolExecutor(max_workers=max(1,args.workers)) as pool: report['tests'].extend(pool.map(run_case,cases))
        if not args.links_only and next(t for t in report['tests'] if t['name']=='compile_compact')['status']=='pass':
            def scene_case(scene):
                name = 'compact_'+scene['name']
                record = command([vvp,run/'compile_compact.vvp',f'+SCENE={scene["scene"]}'], snapshot, args.timeout)
                text = record.get('stdout','')+record.get('stderr','')
                result = dict(name=name, simulation=record,status='pass' if record['returncode']==0 and 'COMPACT_DASHBOARD_TEST_PASS' in text and not FAILURE.search(text) else 'fail')
                print(f'{name}: {result["status"]}',flush=True)
                (run/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
                return result
            with ThreadPoolExecutor(max_workers=max(1,args.workers)) as pool: report['tests'].extend(pool.map(scene_case,report['oracle']))
        report['sources_changed_during_run'] = [name for name, digest in report['sources_sha256'].items() if sha(ROOT/name)!=digest]
        if not report['sources_changed_during_run'] and all(t['status']=='pass' for t in report['tests']): report['status']='pass'
    except Exception as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
    report['elapsed_seconds'] = round(time.monotonic()-started,3)
    report['finished_utc'] = datetime.now(timezone.utc).isoformat()
    result_path = run/'results.json'
    result_path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(status=report['status'],report=str(result_path),tests=len(report['tests']),elapsed_seconds=report['elapsed_seconds']),ensure_ascii=False))
    return 0 if report['status']=='pass' else 1


if __name__=='__main__': raise SystemExit(main())
