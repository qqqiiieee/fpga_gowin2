"""可移动工程的分组回归。各组隔离输出；不访问串口、声卡或板卡。"""
from pathlib import Path
import argparse, os, subprocess, json, shutil, hashlib, time, re
ROOT=Path(__file__).resolve().parents[1]
CORE=['tb_synth_equivalence','tb_audio_hdmi_equivalence','tb_reliable_controls','tb_reliable_cadence',
      'tb_remote_link','tb_instrument_telemetry','tb_wave_scope','tb_oscillator_test_control',
      'tb_oscillator_audio','tb_oscillator_integration','tb_menu_top',
      'tb_tmds_encoder','tb_video_timing','tb_hdmi_link']
def environment(v):
    e=os.environ.copy();b=v/'bin/unwrapped/win64.o'
    dirs=[v/'lib/win64.o',b,v/'tps/mingw/6.2.0/win64.o/nt/bin',
          v/'tps/mingw/6.2.0/win64.o/nt/libexec/gcc/x86_64-w64-mingw32/6.2.0',
          v/'tps/win64/jre17.0.7_7/bin/server',v/'tps/win64/jre17.0.7_7/bin',
          v/'tps/win64/python-3.8.3',v/'tps/win64/python-3.8.3/bin']
    e['PATH']=os.pathsep.join(map(str,dirs))+os.pathsep+e['PATH']
    e.update(XILINX_VIVADO=str(v),RDI_DATADIR=str(v/'data'),RDI_APPROOT=str(v),RDI_BINROOT=str(v/'bin'),
        RDI_LIBDIR=str(v/'lib/win64.o'),RDI_BINDIR=str(v/'bin'),RDI_PLATFORM='win64',RDI_OPT_EXT='.o',
        HDI_APPROOT=str(v),TCL_LIBRARY=str(v/'tps/tcl/tcl8.5'))
    return b,e
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--group',choices=['core','ui','keypad','song','boundaries','host','all'],default='core')
    ap.add_argument('--tests',nargs='+');ap.add_argument('--vivado',type=Path,default=Path(os.environ.get('XILINX_VIVADO','D:/vivado2023.2/Vivado/2023.2')))
    ap.add_argument('--gowin-home',type=Path,default=Path(os.environ.get('GOWIN_HOME','D:/Gowin_V1.9.12.04_x64_win/Gowin/Gowin_V1.9.12.04_x64')))
    a=ap.parse_args();b,e=environment(a.vivado)
    if a.group!='host' and not (b/'xvlog.exe').exists():ap.error('找不到 Vivado XSim；使用 --vivado 或 XILINX_VIVADO 指定安装根目录')
    report={'group':a.group,'project':str(ROOT),'tests':{},'scope':'simulation/mocks only; no hardware','status':'RUNNING'}
    val=ROOT/'validation';val.mkdir(exist_ok=True);dest=val/f'tests_{a.group}.json'
    if a.group in ['core','boundaries','all'] or a.tests:
        tests=a.tests or (CORE if a.group!='boundaries' else ['tb_handoff_boundaries'])
        if a.group=='all':tests=CORE+['tb_handoff_boundaries']
        run=val/'simulation'/f'run_{time.time_ns()}';run.mkdir(parents=True)
        shutil.copytree(ROOT/'src',run/'src');shutil.copytree(ROOT/'tests/fixtures',run/'fixtures')
        shutil.copy2(ROOT/'tests/tmds_vectors.hex',run/'tmds_vectors.hex')
        source=[*sorted((run/'src').glob('*.v')),a.gowin_home/'IDE/simlib/gw2a/prim_sim.v']
        benches=[ROOT/'tests'/(n+'.v') for n in tests]
        # 新边界 bench 可在一个文件声明多个 top。
        for i,p in enumerate(benches):
            if not p.exists() and p.stem.startswith('tb_handoff_'):benches[i]=ROOT/'tests/tb_handoff_boundaries.v'
        extra=[]
        if 'tb_synth_equivalence' in tests:extra+=['legacy_shared_synth.v','legacy_diagnostic_frequency.v']
        if 'tb_reliable_cadence' in tests:extra+=['mock_ads1115.v']
        if 'tb_audio_hdmi_equivalence' in tests:extra+=['baseline_audio_top.v','baseline_instrument_audio.v']
        source+=list(dict.fromkeys(benches))+[ROOT/'tests'/p for p in extra]
        (run/'sources.prj').write_text(''.join('verilog work "'+p.as_posix()+'"\n' for p in source),encoding='utf-8')
        report['source_hashes']={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'src').glob('*') if p.is_file()}
        def tool(name,argv,label,timeout=600):
            log=run/(label+'.log');print('START',label,flush=True)
            with log.open('wb') as out:
                proc=subprocess.Popen([str(b/(name+'.exe'))]+argv,cwd=run,env=e,stdout=out,stderr=subprocess.STDOUT)
                try:code=proc.wait(timeout=timeout)
                except subprocess.TimeoutExpired:proc.kill();proc.wait();raise RuntimeError(f'{label} timeout')
            text=log.read_text(encoding='utf-8',errors='replace')
            if code or re.search(r'Fatal:|\$fatal|ERROR:',text):raise RuntimeError(text[-5000:])
            return text
        try:
            tool('xvlog',['-prj','sources.prj'],'compile',90)
            for test in tests:
                tool('xelab',[test,'-s',test+'_snapshot','--timescale','1ns/1ps','--mt','2'],test+'_elab')
                text=tool('xsim',[test+'_snapshot','-runall'],test+'_sim')
                marker=test.upper().replace('TB_','')+'_TEST_PASS'
                assert marker in text,f'{test} 缺少 PASS 标记'
                print(text[-700:],flush=True)
                report['tests'][test]={'status':'PASS','log':str(run/(test+'_sim.log'))};dest.write_text(json.dumps(report,indent=2),encoding='utf-8')
        except Exception as exc:
            report['status']='FAIL';report['error']=str(exc);dest.write_text(json.dumps(report,indent=2),encoding='utf-8');raise
    if not a.tests:
        for group,script,opts in [('keypad','keypad_tests.py',[]),('song','song_tests.py',[]),('ui','menu_tests.py',['--phase','all'])]:
            if a.group in [group,'all']:
                subprocess.run([os.sys.executable,str(ROOT/'scripts'/script),*opts],cwd=ROOT,env=e,check=True)
                report['tests'][group]={'status':'PASS'}
        if a.group in ['host','all']:
            host_env=e.copy();host_env['PYTHONPATH']=str(ROOT/'tools')
            result=subprocess.run([os.sys.executable,'-B','-m','unittest','discover','-s','tests/Python','-p','test_*.py'],
                cwd=ROOT,env=host_env,capture_output=True)
            log=(result.stdout+result.stderr).decode('utf-8',errors='replace')
            (val/'python_tests.log').write_text(log,encoding='utf-8');print(log[-1600:],flush=True)
            assert result.returncode==0,log[-4000:]
            report['tests']['host']={'status':'PASS','count':int(re.search(r'Ran (\d+) tests',log).group(1)),
                                     'scope':'mocks and synthetic audio, no devices'}
    report['status']='PASS';dest.write_text(json.dumps(report,indent=2),encoding='utf-8');print('GROUP_TEST_PASS',a.group)
if __name__=='__main__':main()
