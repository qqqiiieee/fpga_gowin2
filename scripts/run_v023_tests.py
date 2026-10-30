"""V023离线回归；不会枚举串口、烧录FPGA或连接ESP32。"""
from pathlib import Path
import argparse,hashlib,json,os,subprocess,time

ROOT=Path(__file__).resolve().parents[1]
CASES={
 'tb_phone_control_link':('PHONE_CONTROL_LINK_PASS',60),
 'tb_midi_fx_phone':('MIDI_FX_PHONE',60),
 'tb_v023_system':('V023_SYSTEM_PASS',240),
 'tb_v021_touch_midi_integration':('V021_TOUCH_MIDI_INTEGRATION_PASS',240),
 'tb_pcm5102a_i2s':('PCM5102A_I2S_TEST_PASS',60),
 'tb_midi_uart_rx':('MIDI_UART_RX_TEST_PASS',90),
 'tb_midi_keyboard':('MIDI_KEYBOARD_TEST_PASS',90),
 'tb_optical_strum':('PASS tb_optical_strum scaled',90),
 'tb_analog_touch_keypad':('ANALOG_TOUCH_KEYPAD_TEST_PASS',90),
 'tb_song_rhythm':('SONG_RHYTHM_TEST_PASS',60),
 'tb_oscillator_test_control':('OSCILLATOR_TEST_CONTROL_TEST_PASS',90),
 'tb_touch_reset_constants':('TOUCH_RESET_CONSTANTS_TEST_PASS',60),
 'tb_touch_display_control':('TOUCH_DISPLAY_CONTROL',90),
 'tb_menu_cdc':('MENU_CDC',90),
}

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--resume',action='store_true');args=parser.parse_args()
 out=ROOT/'validation/v023';out.mkdir(exist_ok=True)
 tool=ROOT/'tools/vendor/iverilog-v12/app/bin'
 env=dict(os.environ,PATH=str(tool)+os.pathsep+os.environ.get('PATH',''))
 sources=sorted((ROOT/'src').glob('*.v'))
 tracked=sources+sorted((ROOT/'src').glob('*.vh'))+sorted((ROOT/'src').glob('*.hex'))+sorted((ROOT/'tests').glob('*.v'))+sorted((ROOT/'tests').glob('*.vh'))
 def hashes():return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 before=hashes();reports=[];reusable={}
 if args.resume and (out/'summary.json').is_file():
  previous=json.loads((out/'summary.json').read_text(encoding='utf-8'))
  old=previous['source_hashes'];changed={p for p in set(old)|set(before) if old.get(p)!=before.get(p)}
  # 只改了另一case独立bench时不重跑已通过用例；生产RTL/include任何变化均重跑。
  for record in previous['cases']:
   own='tests/'+record['case']+'.v'
   other_benches={'tests/'+n+'.v' for n in CASES if 'tests/'+n+'.v'!=own}
   if record.get('passed') and changed<=other_benches:
    reusable[record['case']]=record
 for name,(marker,timeout) in CASES.items():
  if name in reusable:
   reports.append(reusable[name]);print(name,'PASS (verified unchanged inputs; reused)',flush=True);continue
  selected=[p for p in sources if not(name=='tb_v023_system' and p.name=='hdmi_live_display.v') and not(name=='tb_menu_cdc' and p.name in ('hdmi_clocks.v','hdmi_tx.v'))]
  output=out/(name+'.vvp')
  argv=[str(tool/'iverilog.exe'),'-g2012','-I',str(ROOT/'src'),'-I',str(ROOT/'tests'),'-s',name,'-o',str(output),*map(str,selected),str(ROOT/'tests'/(name+'.v'))]
  if name=='tb_midi_keyboard':argv.append(str(ROOT/'tests/tb_midi_support.v'))
  start=time.monotonic();r=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
  (out/(name+'_compile.log')).write_text(r.stdout+r.stderr,encoding='utf-8')
  record={'case':name,'compile_argv':argv,'compile_exit':r.returncode,'run_argv':[str(tool/'vvp.exe'),str(output)],'timeout_seconds':timeout}
  log='';code=None
  if r.returncode==0:
   try:
    run=subprocess.run(record['run_argv'],cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=timeout)
    log=run.stdout+run.stderr;code=run.returncode
   except subprocess.TimeoutExpired as exc:log='TIMEOUT\n'+str(exc)
  (out/(name+'_run.log')).write_text(log,encoding='utf-8')
  record.update(run_exit=code,pass_marker=marker,passed=r.returncode==0 and code==0 and marker in log and 'FATAL:' not in log,elapsed_seconds=round(time.monotonic()-start,3))
  reports.append(record);print(name,'PASS' if record['passed'] else 'FAIL',record['elapsed_seconds'],flush=True)
  data={'cases':reports,'source_hashes':before,'source_hashes_match':before==hashes(),'hardware_programmed':False,'physical_validation':False}
  (out/'summary.json').write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
  if not record['passed']:raise SystemExit(1)
 assert before==hashes(),'回归期间文件改变，需重跑'
 print('V023_REGRESSION_PASS',len(reports),flush=True)

if __name__=='__main__':main()
