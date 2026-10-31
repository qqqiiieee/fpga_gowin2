from pathlib import Path
import json,hashlib,subprocess,datetime,time,re,sys
ROOT=Path(__file__).resolve().parents[2]
BIN=Path(r'D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
OUT=ROOT/'tests/phone_extensions/state_midi_results'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
OUT.mkdir(parents=True)
NAMES=['src/phone_extension_state.v','src/midi_keyboard.v','src/midi_uart_rx.v','tests/phone_extensions/tb_state_midi_real.v']
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
before={name:sha(ROOT/name) for name in NAMES}
for name in NAMES:
 f=OUT/'snapshot'/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes((ROOT/name).read_bytes())
cmd=[str(BIN/'iverilog.exe'),'-g2012','-s','tb_state_midi_real','-o',str(OUT/'test.vvp')]+[str(OUT/'snapshot'/name) for name in NAMES]
c=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=30)
(OUT/'compile.log').write_text(c.stdout+c.stderr,encoding='utf8')
start=time.time()
if c.returncode==0:
 try:r=subprocess.run([str(BIN/'vvp.exe'),str(OUT/'test.vvp')],cwd=ROOT,capture_output=True,text=True,timeout=90);code=r.returncode;log=r.stdout+r.stderr
 except subprocess.TimeoutExpired as e:code=-1;log='TIMEOUT '+str(e)
else:code=c.returncode;log=c.stdout+c.stderr
(OUT/'run.log').write_text(log,encoding='utf8')
after={name:sha(ROOT/name) for name in NAMES}
match=re.search(r'STATE_MIDI_REAL_PASS (.+)',log)
metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',match[1])} if match else {}
findings=[]
if metrics.get('accepts_while_new_note_held'):
 findings.append({'priority':'P2','file':'src/phone_extension_state.v','line':71,'finding':'MAP_COMMIT holds the request until decoder ack but does not recheck performance_idle. A new valid MIDI NoteOn arriving after the initial ready/idle precheck can become held while ready is low; once the UART quiet guard expires, commit accepts and panic cuts that new held note. This is not an early ACK or duplicate commit.','reproduced':True})
result={'passed':code==0 and match is not None and before==after,'scope':'Unmodified real phone_extension_state + midi_keyboard + midi_uart_rx.27MHz rational1ps clock,31250baud UART864clocks/bit. Commands enter the executor request ports directly, not phone framed RPC/ESP/audio output. Ready/ack are NOT stubbed. No force, no hardware, no production RTL edits.','metrics':metrics,'policy_findings':findings,'source_sha256_before':before,'source_sha256_after':after,'production_files_unchanged':all(before[n]==after[n] for n in NAMES if n.startswith('src/')),'command':cmd,'returncode':code,'wall_seconds':time.time()-start,'run_log':str(OUT/'run.log')}
(OUT/'results.json').write_text(json.dumps(result,indent=2),encoding='utf8')
(ROOT/'tests/phone_extensions/state_midi_latest.json').write_text(json.dumps({'results':str(OUT/'results.json'),'passed':result['passed'],'policy_findings':findings},indent=2),encoding='utf8')
print(log,flush=True);print('RESULTS '+str(OUT/'results.json'),flush=True)
sys.exit(0 if result['passed'] else 1)
