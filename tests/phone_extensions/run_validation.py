from pathlib import Path
import subprocess,json,hashlib,time,concurrent.futures,struct,zlib,re,sys,datetime
ROOT=Path(__file__).resolve().parents[2]
BIN=Path(r'D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
SIM_TIMEOUT=int(sys.argv[sys.argv.index('--sim-timeout')+1]) if '--sim-timeout' in sys.argv else 180
STAMP=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
OUT=ROOT/'validation/phone_extensions'/STAMP;OUT.mkdir(parents=True,exist_ok=True)
def run(top,tb,params=(),args=(),sources=None,label=None):
 name=label or top;binary=OUT/(name+'.vvp')
 cmd=[str(BIN/'iverilog.exe'),'-g2012','-I','.', '-I','tests','-s',top,'-o',str(binary)]+list(params)+[tb]+(sources if sources is not None else [str(f.relative_to(ROOT)) for f in (ROOT/'src').glob('*.v')])
 if top in ['tb_midi_keyboard','tb_midi_release','tb_midi_cc_events']:cmd.append('tests/tb_midi_support.v')
 t=time.time();c=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=30)
 (OUT/(name+'_compile.log')).write_text(c.stdout+c.stderr,encoding='utf8')
 if c.returncode:return {'name':name,'passed':False,'stage':'compile','output':c.stdout+c.stderr,'command':cmd}
 try:r=subprocess.run([str(BIN/'vvp.exe'),str(binary)]+list(args),cwd=ROOT,capture_output=True,text=True,timeout=SIM_TIMEOUT)
 except subprocess.TimeoutExpired:return {'name':name,'passed':False,'stage':'timeout'}
 output=r.stdout+r.stderr;(OUT/(name+'.log')).write_text(output,encoding='utf8')
 return {'name':name,'passed':r.returncode==0,'output':output,'seconds':time.time()-t,'command':cmd,'run_args':list(args)}
def raw(i):
 group=(i//6)%7;j=i%6
 return [-32768,-5+j,5-j,32767,32767 if i%2 else -32768,100+j,-100-j][group]
def validate_record(r,n,overflow=False,saturated=False):
 if not r['passed']:return
 values=[int(sum(raw(i*6+j) for j in range(6))/6) for i in range(n)]
 crc=zlib.crc32(b''.join(struct.pack('<h',v) for v in values))
 received={0:[],1:[]};eofs={}
 for line in r['output'].splitlines():
  m=re.match(r'REC_DATA session=(\d+) a=(-?\d+) b=(-?\d+) c=(-?\d+)',line)
  if m:received[int(m[1])].extend(map(int,m.groups()[1:]))
  m=re.match(r'REC_EOF session=(\d+) count=(\d+) dropped=(\d+) crc=([0-9a-fA-F]+)',line)
  if m:eofs[int(m[1])]={'count':int(m[2]),'dropped':int(m[3]),'crc':int(m[4],16)}
 try:
  assert eofs[0]['count']==n
  expected_dropped=min(65535,max(0,n-515)) if overflow else 0
  assert eofs[0]['dropped']==expected_dropped,(eofs[0],expected_dropped)
  assert eofs[0]['crc']==crc,(hex(eofs[0]['crc']),hex(crc))
  actual=n if not overflow else min(515,n)
  assert received[0][:actual]==values[:actual]
  assert len(received[0])==((actual+2)//3)*3
  assert all(v==0 for v in received[0][actual:])
  assert eofs[1]=={'count':0,'dropped':0,'crc':0}
  assert received[1]==[]
  assert 'RECORD_TEST_PASS' in r['output']
  r['reference']={'generated_samples':n,'transmitted_valid_samples':actual,'dropped':expected_dropped,'expected_crc32':f'{crc:08x}','crc_reference':'Python zlib.crc32 of signed16 little-endian generated samples, excluding padding','recording_complete':not overflow}
 except (AssertionError,KeyError) as e:r['passed']=False;r['reference_failure']=repr(e)
def main():
 tasks=[('tb_mapping_release','tests/phone_extensions/tb_mapping_release.v',[],[],None,'mapping_release'),('tb_mapping','tests/phone_extensions/tb_mapping.v',[],[],None,'mapping_integrated'),
 ('tb_phone_record_tap','tests/phone_extensions/tb_phone_record_tap.v',['-Ptb_phone_record_tap.LIMIT=7'],['+CASE=0'],['src/phone_record_tap.v'],'record_limit7'),
 ('tb_phone_record_tap','tests/phone_extensions/tb_phone_record_tap.v',['-Ptb_phone_record_tap.LIMIT=32'],['+CASE=1'],['src/phone_record_tap.v'],'record_stop_partial'),
 ('tb_phone_record_tap','tests/phone_extensions/tb_phone_record_tap.v',['-Ptb_phone_record_tap.LIMIT=700'],['+CASE=2'],['src/phone_record_tap.v'],'record_overflow700'),
 ('tb_phone_record_tap','tests/phone_extensions/tb_phone_record_tap.v',['-Ptb_phone_record_tap.LIMIT=70000'],['+CASE=3'],['src/phone_record_tap.v'],'record_drop_saturation')]
 for top in ['tb_midi_keyboard','tb_midi_release','tb_midi_cc_events','tb_midi_control_bank']:
  tasks.append((top,'tests/'+top+'.v',[],[],None,'legacy_'+top))
 rows=[]
 reused=None
 if '--reuse-passed' in sys.argv:
  reused=Path(sys.argv[sys.argv.index('--reuse-passed')+1])
  previous=json.loads(reused.read_text())
  old_hashes=previous['source_sha256']
  source_stable=all(hashlib.sha256((ROOT/f).read_bytes()).hexdigest()==h for f,h in old_hashes.items() if f.startswith('src/'))
  for r in previous['tests']:
   if not r['passed'] or not source_stable:continue
   changed=False
   for arg in r.get('command',[]):
    if arg in old_hashes and (ROOT/arg).is_file() and hashlib.sha256((ROOT/arg).read_bytes()).hexdigest()!=old_hashes[arg]:changed=True
   if not changed:
    cached=dict(r,reused_from=str(reused))
    if cached['name'].startswith('record_'):
     n={'record_limit7':7,'record_stop_partial':5,'record_overflow700':700,'record_drop_saturation':70000}[cached['name']]
     validate_record(cached,n,'overflow' in cached['name'] or 'saturation' in cached['name'])
    rows.append(cached)
  done={r['name'] for r in rows};tasks=[t for t in tasks if t[5] not in done]
 with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
  futures=[ex.submit(run,*t) for t in tasks]
  for f in concurrent.futures.as_completed(futures):
   row=f.result()
   if row['name'].startswith('record_'):
    n={'record_limit7':7,'record_stop_partial':5,'record_overflow700':700,'record_drop_saturation':70000}[row['name']]
    validate_record(row,n,'overflow' in row['name'] or 'saturation' in row['name'])
   rows.append(row);print(row['name'],row['passed'],row.get('reference_failure',''),flush=True)
 base=json.loads((ROOT/'validation/phone_extensions/baseline_hashes.json').read_text())
 canonical=Path(r'D:/Gowin_project/instrument_piano_f32_20261030')
 canon_changed=[f for f,h in base['canonical'].items() if hashlib.sha256((canonical/f).read_bytes()).hexdigest()!=h]
 owned={'src/'+f for f in ['midi_keyboard.v','performance_input_hub.v','instrument_inputs.v','instrument_audio_top.v']}
 other_changed=[f for f,h in base['workspace'].items() if f not in owned and hashlib.sha256((ROOT/f).read_bytes()).hexdigest()!=h]
 files=[ROOT/arg for r in rows for arg in r.get('command',[]) if (ROOT/arg).is_file() and arg.endswith(('.v','.vh'))]+[ROOT/f for f in owned]+[ROOT/'src/phone_record_tap.v']+list((ROOT/'tests/phone_extensions').glob('*.v'))+[Path(__file__)]
 result={'passed':all(r['passed'] for r in rows) and not canon_changed,'tests':rows,'canonical_changed':canon_changed,'parallel_source_differences_since_baseline':other_changed,'parallel_difference_policy':'Read-only observation; other task edits are preserved and do not fail these owned-module tests.','source_sha256':{str(f.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},'hardware_accessed':False,'gowin_synthesis_or_pnr_run':False,'bram_inference':'Synchronous512x16 FIFO and256x7 map coded with block_ram attributes; actual Gowin resource inference not validated','scope':'Icarus functional simulation only; no physical audio, serial transport/RPC/ESP integration or bitstream.'}
 (OUT/'results.json').write_text(json.dumps(result,indent=2),encoding='utf8');(ROOT/'validation/phone_extensions/latest.json').write_text(json.dumps({'results':str(OUT/'results.json'),'passed':result['passed']},indent=2))
 print('RESULTS',OUT/'results.json','PASS' if result['passed'] else 'FAIL',flush=True)
if __name__=='__main__':main()
