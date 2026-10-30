"""V021专职触摸屏控：明确选择的新集成与保留协议测试，记录命令/退出码/输入哈希。"""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, time

ROOT=Path(__file__).resolve().parents[1]
CASES={
 'tb_song_rhythm':('SONG_RHYTHM_TEST_PASS',60),
 'tb_touch_reset_constants':('TOUCH_RESET_CONSTANTS_TEST_PASS',60),
 'tb_v021_touch_midi_integration':('V021_TOUCH_MIDI_INTEGRATION_PASS',1200),
 'tb_pcm5102a_i2s':('PCM5102A_I2S_TEST_PASS',60),
 'tb_oscillator_test_control':('OSCILLATOR_TEST_CONTROL_TEST_PASS',120),
 'tb_midi_uart_rx':('MIDI_UART_RX_TEST_PASS',90),
 'tb_midi_keyboard':('MIDI_KEYBOARD_TEST_PASS',90),
 'tb_optical_strum':('PASS tb_optical_strum scaled',90),
 'tb_analog_touch_keypad':('ANALOG_TOUCH_KEYPAD_TEST_PASS',90),
}

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--tests',nargs='+',choices=CASES,default=list(CASES))
 ap.add_argument('--compile-only',action='store_true')
 ap.add_argument('--resume',action='store_true',help='仅复用输入哈希完全一致且实际已通过的当前目录用例')
 args=ap.parse_args()
 out=ROOT/'validation/v021';out.mkdir(parents=True,exist_ok=True)
 tool=ROOT/'tools/vendor/iverilog-v12/app/bin'
 env=dict(os.environ);env['PATH']=str(tool)+os.pathsep+env.get('PATH','')
 sources=sorted((ROOT/'src').glob('*.v'))
 # 全部生产源码参与语法检查，-s仅展开当前bench需要的层次，不模拟未使用的厂商HDMI原语。
 tracked=sources+sorted((ROOT/'src').glob('*.vh'))+sorted((ROOT/'src').glob('*.hex'))+[ROOT/'tests'/(n+'.v') for n in CASES]+[ROOT/'tests/tb_midi_support.v']+sorted((ROOT/'tests').glob('*.vh'))
 before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 reports=[]
 previous={}
 prior=out/'summary.json'
 if args.resume and prior.is_file() and not args.compile_only:
  data=json.loads(prior.read_text(encoding='utf-8'))
  if data.get('source_hashes')==before and not data.get('compile_only'):
   previous={x['case']:x for x in data['cases'] if x.get('pass') and x.get('run_returncode')==0}
 for name in args.tests:
  if name in previous:
   reports.append(previous[name]);print(name,'PASS (same input hashes; reused)',flush=True);continue
  marker,timeout=CASES[name];vvp=out/(name+'.vvp')
  argv=[str(tool/'iverilog.exe'),'-g2012','-I',str(ROOT/'src'),'-I',str(ROOT/'tests'),'-s',name,'-o',str(vvp),*map(str,sources),str(ROOT/'tests'/(name+'.v'))]
  if name=='tb_midi_keyboard':argv.append(str(ROOT/'tests/tb_midi_support.v'))
  record={'case':name,'compile_argv':argv,'run_argv':[str(tool/'vvp.exe'),str(vvp)],'timeout':timeout}
  start=time.monotonic()
  compiled=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
  (out/(name+'_compile.log')).write_text(compiled.stdout+compiled.stderr,encoding='utf-8')
  record['compile_returncode']=compiled.returncode
  if compiled.returncode==0 and not args.compile_only:
   try:
    ran=subprocess.run(record['run_argv'],cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=timeout)
    log=ran.stdout+ran.stderr;record['run_returncode']=ran.returncode
    record['pass']=ran.returncode==0 and marker in log and 'FATAL:' not in log
   except subprocess.TimeoutExpired as exc:
    log='TIMEOUT\n'+str(exc);record['run_returncode']=None;record['pass']=False
   (out/(name+'_run.log')).write_text(log,encoding='utf-8')
  else:record['pass']=compiled.returncode==0 and args.compile_only
  record['elapsed_seconds']=round(time.monotonic()-start,3);reports.append(record)
  print(name,'PASS' if record['pass'] else 'FAIL',record['elapsed_seconds'],flush=True)
  (out/'summary.json').write_text(json.dumps({'cases':reports,'source_hashes':before,'compile_only':args.compile_only},ensure_ascii=False,indent=2),encoding='utf-8')
  if not record['pass']:break
 after={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 if before!=after:raise SystemExit('生产源码在测试期间变化，须待工作完成后重跑受影响测试。')
 if not all(x['pass'] for x in reports) or len(reports)!=len(args.tests):raise SystemExit(1)

if __name__=='__main__':main()
