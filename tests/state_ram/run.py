from pathlib import Path
import subprocess,json,hashlib,datetime,sys
R=Path(__file__).resolve().parents[2]
B=Path(r'D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
O=R/'validation/state_ram'/datetime.datetime.now().strftime('%Y%m%d_%H%M%S');O.mkdir(parents=True)
files=['tests/state_ram/tb_state_ram.v','tests/state_ram/baseline/wavetable_synth_reference.v','src/wavetable_synth.v','src/note_table.v','src/oscillator_test_frequencies.v']
results=[]
for live in [0,1]:
 v=O/f'live{live}.vvp'
 c=subprocess.run([str(B/'iverilog.exe'),'-g2012','-s','tb_state_ram',f'-Ptb_state_ram.LIVE={live}','-o',str(v)]+files,cwd=R,capture_output=True,text=True,timeout=30)
 run=subprocess.run([str(B/'vvp.exe'),str(v)],cwd=R,capture_output=True,text=True,timeout=180) if c.returncode==0 else c
 log=c.stdout+c.stderr+run.stdout+run.stderr;(O/f'live{live}.log').write_text(log,encoding='utf8');print(log,flush=True)
 results.append({'live':live,'pass':run.returncode==0 and 'STATE_RAM_EQUIVALENCE_PASS' in log})
d={'passed':all(x['pass'] for x in results),'results':results,'sha256':{f:hashlib.sha256((R/f).read_bytes()).hexdigest() for f in files},'scope':'Cycle-exact frozen reference vs legacy branch vs STATE_RAM=1. 32 voices, both timbres, live ADSR on/off, pressure, test-mode, retrigger, early fs_tick, reset mid-frame. No analog measurement.'}
(O/'results.json').write_text(json.dumps(d,indent=2),encoding='utf8');(R/'validation/state_ram_latest.json').write_text(json.dumps({'path':str(O),'passed':d['passed']},indent=2),encoding='utf8');sys.exit(0 if d['passed'] else 1)
