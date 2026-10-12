"""Isolated UI RTL tests. Only three owned benches and menu_agent_sim outputs.

Preview first, then controller/CDC/probes. No song_guide, audio engine,
production edits, hardware, programming or serial access.
"""
from __future__ import annotations
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
try:
    from PIL import Image, ImageDraw
except ModuleNotFoundError:
    bundled=Path('C:/Users/31989/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe')
    if bundled.exists() and Path(sys.executable).resolve()!=bundled.resolve():
        raise SystemExit(subprocess.call([str(bundled),str(Path(__file__).resolve()),*sys.argv[1:]]))
    raise

ROOT = Path(__file__).resolve().parents[1]
VIVADO = Path(os.environ.get('XILINX_VIVADO','D:/vivado2023.2/Vivado/2023.2'))
PALETTE = dict(BG=0x0b101c, PANEL=0x172338, BORDER=0x34465f, GRID=0x22324a,
               TEXT=0xe2e8f0, MUTED=0x91a4be, CYAN=0x51d6e8, GREEN=0x21c6a8,
               AMBER=0xf4bb4f, ALERT=0xff5964)
SCENES = ['LIVE_song0', 'LIBRARY_song1_cursor1', 'HELP_keys_cursor2', 'DIAG_S9_S10_S7', 'TEST32_priority']
# Fixed 5x7 grid oracle for diagnostic S01..S16; independent of renderer/ROM.
GLYPHS = {'S':0x3e107043e, '0':0x3a33ae62e, '1':0x11842108e,
          '2':0x3a211111f, '3':0x78217043e, '4':0x08ca97c42,
          '5':0x7e10f043e, '6':0x3a10f462e, '7':0x7c2222108,
          '8':0x3a317462e, '9':0x3a317842e, ' ':0}

def color(n):
    return ((n>>16)&255, (n>>8)&255, n&255)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def environment():
    v=VIVADO; env=os.environ.copy()
    paths=[v/'lib/win64.o',v/'bin/unwrapped/win64.o',v/'tps/mingw/6.2.0/win64.o/nt/bin',
           v/'tps/mingw/6.2.0/win64.o/nt/libexec/gcc/x86_64-w64-mingw32/6.2.0',
           v/'tps/win64/jre17.0.7_7/bin/server',v/'tps/win64/jre17.0.7_7/bin',
           v/'tps/win64/python-3.8.3',v/'tps/win64/python-3.8.3/bin']
    env['PATH']=os.pathsep.join(map(str,paths))+os.pathsep+env['PATH']
    env.update(XILINX_VIVADO=str(v),RDI_DATADIR=str(v/'data'),RDI_APPROOT=str(v),
               RDI_BINROOT=str(v/'bin'),RDI_LIBDIR=str(v/'lib/win64.o'),RDI_BINDIR=str(v/'bin'),
               RDI_PLATFORM='win64',RDI_OPT_EXT='.o',HDI_APPROOT=str(v),TCL_LIBRARY=str(v/'tps/tcl/tcl8.5'))
    return env

class Oracle:
    def __init__(self, run):
        self.layout=json.loads((run/'inputs/menu_layout.json').read_text(encoding='utf-8'))
        self.mapping=json.loads((run/'inputs/ui_font_map.json').read_text(encoding='utf-8'))
        self.rom=[int(x,16) for x in (run/'src/ui_font.hex').read_text().split()]
        assert len(self.rom)==8192
        assert self.mapping['unique_hanzi_count']==192
        assert self.mapping['hanzi']['码']==[510,511]
        assert any(self.rom[510*16:511*16]) and any(self.rom[511*16:512*16])
        assert self.layout['songs']==['小星星','欢乐颂','两只老虎']
        self.songs=['小星星跟弹','欢乐颂','两只老虎']
    def codes(self, text, cells=32):
        result=[]
        for c in text:
            result += [ord(c)] if ord(c)<128 else self.mapping['hanzi'][c]
        assert len(result)<=cells,(text,len(result),cells)
        return result+[32]*(cells-len(result))
    def text(self, img, x, y, width, text, ink, substitutions=None):
        codes=self.codes(text)
        if substitutions:
            for start,s in substitutions:
                codes[start:start+len(s)]=[ord(c) for c in s]
        pixels=img.load()
        for dx in range(width):
            for dy in range(16):
                if self.rom[codes[dx//8]*16+dy] & (1<<(7-dx%8)):
                    pixels[x+dx,y+dy]=color(ink)
    def frame(self,page,cursor=0,song=0,keys=0,flags=0):
        img=Image.new('RGB',(640,480),color(PALETTE['BG']));draw=ImageDraw.Draw(img)
        if page==1:
            for i in range(3):
                yy=96+i*80
                draw.rectangle((32,yy,607,yy+55),fill=color(PALETTE['PANEL']),
                               outline=color(PALETTE['AMBER' if cursor==i else 'BORDER']))
                if song==i:draw.rectangle((33,yy+1,35,yy+54),fill=color(PALETTE['GREEN']))
        if page==3:
            for i in range(16):
                xx=32+(i%4)*64;yy=160+(i//4)*48;down=bool(keys&(1<<i))
                draw.rectangle((xx,yy,xx+55,yy+39),fill=color(PALETTE['CYAN' if down else 'PANEL']),
                               outline=color(PALETTE['BORDER']))
                for ci,c in enumerate(f'S{i+1:02d}'):
                    glyph=GLYPHS[c]
                    for gy in range(7):
                        for gx in range(5):
                            if glyph & (1<<(34-gy*5-gx)):
                                draw.rectangle((xx+4+ci*16+gx*2,yy+12+gy*2,
                                                xx+5+ci*16+gx*2,yy+13+gy*2),
                                               fill=color(PALETTE['BG' if down else 'MUTED']))
        rects=[]
        for i,f in enumerate(self.layout['fields']):
            if f['page']!=page:continue
            if page==2 and 17<=i<=43 and (i-17)//9!=cursor:continue
            text=f['text']; ink=f['ink'];subs=[]
            if page==1 and i==11:text=self.songs[song if song<3 else 0]
            if page==2 and i==16:subs=[(0,f'{cursor+1:02d}')]
            if f['kind']==5:subs=[(7,f'{keys:04X}')]
            if page==3:
                if i==56:subs=[(5,'073')]
                if i==57:subs=[(6,'000')]
                if i==58:subs=[(4,'088')]
                if i==59:subs=[(4,'128')]
                if i==60:text='ADC 故障' if flags&0x18 else 'ADC 正常'
                if i==61:text='远控' if flags&2 else '键盘'
            if ink.startswith('ui_cursor'):
                selected=int(re.search(r'==([0-2])',ink)[1]);ink='AMBER' if cursor==selected else 'TEXT'
            elif ink.startswith('flags[3]'):ink='ALERT' if flags&0x18 else 'GREEN'
            elif ink.startswith('flags[1]'):ink='AMBER' if flags&2 else 'CYAN'
            self.text(img,f['x'],f['y'],f['width'],text,PALETTE[ink],subs)
            rects.append((f['x'],f['y'],f['width'],f['height']))
        return img,rects
    def artifacts(self,run):
        for name,state in [(SCENES[1],(1,1,1,0,0)),(SCENES[2],(2,2,0,0x0140,0)),(SCENES[3],(3,0,0,0x0340,0))]:
            img,_=self.frame(*state)
            pixels=img.get_flattened_data() if hasattr(img,'get_flattened_data') else img.getdata()
            (run/(name+'.hex')).write_text(''.join(f'{(r<<16)|(g<<8)|b:06x}\n' for r,g,b in pixels),encoding='ascii')
        count=0
        with (run/'menu_vectors.txt').open('w',encoding='ascii') as stream:
            def region(img,state,rect,guide=0,de=1):
                nonlocal count
                page,cursor,song,keys,flags=state; pixels=img.load();xx,yy,w,h=rect
                for y in range(yy,yy+h):
                    for x in range(xx,xx+w):
                        r,g,b=pixels[x,y];rgb=(r<<16)|(g<<8)|b
                        stream.write(f'{page} {cursor} {song} {keys:04x} {flags:02x} {guide} {de} {x} {y} {rgb:06x}\n');count+=1
            # All three actual titles and cursor/song combinations.
            for song in range(3):
                for cursor in range(3):
                    state=(1,cursor,song,0,0);img,rects=self.frame(*state)
                    for rect in rects:region(img,state,rect)
                    for row in range(3):
                        yy=96+80*row
                        for rect in [(31,yy-1,578,2),(31,yy+55,578,2),(31,yy,6,56),(606,yy,3,56)]:region(img,state,rect)
            # HELP themes and full 16-bit key code. Explicit S9 / S7 examples.
            for cursor in range(3):
                for keys in [0x0100,0x0040,0x8000,0xffff]:
                    state=(2,cursor,0,keys,0);img,rects=self.frame(*state)
                    for rect in rects:region(img,state,rect)
            # Every single diagnostic key: whole 16-key grid plus labels/footer.
            for keys in [0,0xffff,0x0340]+[1<<i for i in range(16)]:
                state=(3,0,0,keys,0);img,rects=self.frame(*state)
                region(img,state,(31,159,258,194))
                region(img,state,(32,64,256,16))
            for flags in [0,2,8,16,0x1a,0x80]:
                state=(3,0,0,0x0340,flags);img,rects=self.frame(*state)
                for rect in rects:region(img,state,rect)
            # LIVE: independent actual title at two locations + common footer.
            for song in range(4):
                state=(0,0,song,0,0)
                img=Image.new('RGB',(640,480),color(PALETTE['BG']))
                title=self.songs[song if song<3 else 0]
                self.text(img,368,16,256,title,PALETTE['AMBER'])
                self.text(img,304,296,256,title,PALETTE['AMBER'])
                for f in self.layout['fields']:
                    if f['page']==0:self.text(img,f['x'],f['y'],f['width'],f['text'],PALETTE[f['ink']])
                for rect in [(368,16,256,16),(304,296,256,16),(32,448,256,16),(320,448,256,32)]:region(img,state,rect,guide=1)
            # Adjacent RGB samples must immediately blank, no stale font or color.
            for page in range(4):
                for de in [0,1]:
                    for x,y in [(640,16),(1023,479),(32,480),(639,1023),(1023,1023)]+([(32,16),(368,16),(639,479)] if not de else []):
                        stream.write(f'{page} 2 2 ffff 80 1 {de} {x} {y} 000000\n');count+=1
        return count

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase',choices=['preview','all','checks','legacy'],default='all')
    parser.add_argument('--run-dir',type=Path)
    args=parser.parse_args()
    base=ROOT/'validation/menu_agent_sim';base.mkdir(parents=True,exist_ok=True)
    run=args.run_dir or base/('run_'+datetime.now().strftime('%Y%m%d_%H%M%S')+f'_{os.getpid()}')
    run.mkdir(parents=True,exist_ok=True);(run/'src').mkdir(exist_ok=True);(run/'inputs').mkdir(exist_ok=True)
    report={'status':'RUNNING','run_directory':str(run),'phase':args.phase,'tests':{},'commands':[],
            'sources':[],'started':datetime.now().astimezone().isoformat(),
            'scope':'UI control, renderer, wrapper CDC only; no song/audio/hardware'}
    def save():
        (run/'results.json').write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding='utf-8')
        (base/'latest.json').write_text(json.dumps({'run_directory':str(run),'results_path':str(run/'results.json'),
            'report_path':str(run/'report.md'),'phase':report['phase'],'status':report['status']},indent=2),encoding='utf-8')
    def snapshot(path,dest=None):
        dest=dest or run/'src'/path.name
        data=path.read_bytes();dest.write_bytes(data)
        report['sources'].append({'path':str(path),'snapshot':str(dest),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
        return dest
    def tool(name,argv,label,timeout=360):
        exe=VIVADO/'bin/unwrapped/win64.o'/(name+'.exe');cmd=[str(exe)]+argv;log=run/(label+'.log')
        report['commands'].append({'command':cmd,'cwd':str(run),'log':str(log)});save()
        print('START',label,flush=True)
        with log.open('wb') as out:
            proc=subprocess.Popen(cmd,cwd=run,env=environment(),stdout=out,stderr=subprocess.STDOUT)
            try:code=proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:proc.kill();proc.wait();raise RuntimeError(f'{label} timeout; only own child stopped')
        text=log.read_text(encoding='utf-8',errors='replace')
        if code or re.search(r'Fatal:|\$fatal|ERROR:',text):raise RuntimeError(f'{label} exit={code}\n{text[-5000:]}')
        print(text[-800:],flush=True);return text
    def simulate(top,marker,plusargs=(),label=None):
        label=label or top; snap=top+'_snapshot'
        tool('xelab',[top,'-s',snap,'--timescale','1ns/1ps','--mt','2'],label+'_elaborate')
        argv=[snap,'-runall']
        for p in plusargs:argv+=['-testplusarg',p]
        out=tool('xsim',argv,label+'_simulate',timeout=600)
        if marker not in out:raise RuntimeError(f'{label} missing {marker}')
        report['tests'][label]={'status':'PASS','marker':marker,'log':str(run/(label+'_simulate.log'))};save()
    try:
        names=['hdmi_instrument_dashboard','hdmi_ui_font']
        benches=['tb_menu_preview']
        if args.phase in ['all','checks']:
            names+=['instrument_ui_control','hdmi_live_display','hdmi_status_cdc','video_timing','wave_scope']
            benches+=['tb_instrument_ui_control','tb_menu_cdc']
        if args.phase=='legacy':benches=['tb_hdmi_zh_pipeline','tb_hdmi_live_preview','tb_hdmi_test_preview']
        sources=[snapshot(ROOT/'src'/(n+'.v')) for n in names]
        sources += [snapshot(ROOT/'tests'/(n+'.v')) for n in benches]
        snapshot(ROOT/'src/ui_font.hex')
        snapshot(ROOT/'src/hdmi_ui_text.vh')
        for n in ['menu_layout.json','ui_font_map.json']:snapshot(ROOT/'assets'/n,run/'inputs'/n)
        snapshot(Path(__file__),run/'inputs/menu_tests.py')
        save()
        if args.phase!='legacy':report['independent_vectors']=Oracle(run).artifacts(run);save()
        prj=run/'sources.prj';prj.write_text(''.join(f'verilog work "{str(p).replace(chr(92),chr(47))}"\n' for p in sources),encoding='utf-8')
        tool('xvlog',['-prj','sources.prj'],'compile',timeout=90)
        if args.phase in ['preview','all']:
            simulate('tb_menu_preview','MENU_PREVIEW_FRAMES_PASS',['FRAMES_ONLY'],'menu_frames')
            images=[]
            for name in SCENES:
                ppm=run/(name+'.ppm');png=run/(name+'.png')
                with Image.open(ppm) as img:
                    assert img.size==(640,480);img.save(png)
                images.append({'scene':name,'ppm':str(ppm),'png':str(png),'ppm_sha256':digest(ppm),'png_sha256':digest(png)})
            report['images']=images;save();print('MENU_FIVE_PREVIEWS_READY',run,flush=True)
        if args.phase in ['all','checks']:
            simulate('tb_instrument_ui_control','INSTRUMENT_UI_CONTROL_TEST_PASS')
            simulate('tb_menu_cdc','MENU_CDC_TEST_PASS')
            simulate('tb_menu_preview','MENU_PREVIEW_TEST_PASS',['CHECKS_ONLY'],'menu_checks')
        if args.phase=='legacy':
            for top,marker in [('tb_hdmi_zh_pipeline','HDMI_ZH_PIPELINE_TEST_PASS'),('tb_hdmi_live_preview','HDMI_LIVE_PREVIEW_PASS'),('tb_hdmi_test_preview','HDMI_TEST_PREVIEW_TEST_PASS')]:simulate(top,marker)
        report['status']='PASS'
    except Exception as exc:
        report['status']='FAIL';report['error']=str(exc);print(str(exc),file=sys.stderr,flush=True)
    finally:
        report['finished']=datetime.now().astimezone().isoformat()
        report['source_current_checks']=[{'path':s['path'],'snapshot_sha256':s['sha256'],'current_sha256':digest(Path(s['path'])),'unchanged':digest(Path(s['path']))==s['sha256']} for s in report['sources']]
        save()
        (run/'report.md').write_text('# Isolated menu RTL validation\n\nStatus: '+report['status']+'\n\n'+
            '\n'.join(f'- {name}: {result["status"]} ({result["marker"]})' for name,result in report['tests'].items())+
            '\n\nIndependent expected values: layout JSON, fixed key geometry/5x7 glyphs, separate ROM storage, explicit CDC bit offsets.\n'+
            'Clock/TMDS boundary models are test-only; physical HDMI is outside this validation.\n'+
            ('\nError: '+report['error']+'\n' if 'error' in report else ''),encoding='utf-8')
    print('MENU_AGENT_'+report['status'],run,flush=True)
    return 0 if report['status']=='PASS' else 1

if __name__=='__main__':raise SystemExit(main())
