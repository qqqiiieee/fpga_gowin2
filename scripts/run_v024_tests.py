"""V024整合回归。并行只运行独立仿真，不打开串口或下载器。"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import argparse,hashlib,json,os,subprocess,time
from run_v023_tests import CASES as INHERITED
ROOT=Path(__file__).resolve().parents[1]
CASES={k:v for k,v in INHERITED.items() if k!='tb_v023_system'}
CASES.update(tb_v024_system=('V024_SYSTEM_PASS',240),
             tb_note_table_midi_range=('NOTE_TABLE_MIDI_RANGE_TEST_PASS',60))

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--workers',type=int,default=2)
    ap.add_argument('--case',action='append',choices=list(CASES));ap.add_argument('--reuse-passed',action='store_true');args=ap.parse_args()
    selected=args.case or list(CASES)
    out=ROOT/'validation/v024';out.mkdir(exist_ok=True)
    tool=ROOT/'tools/vendor/iverilog-v12/app/bin'
    env=dict(os.environ,PATH=str(tool)+os.pathsep+os.environ.get('PATH',''))
    src=sorted((ROOT/'src').glob('*.v'))
    tracked=[p for p in (ROOT/'src').glob('*') if p.is_file()]+list((ROOT/'tests').glob('*.v'))+list((ROOT/'tests').glob('*.vh'))
    def hashes():return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    before=hashes();reusable={}
    if args.reuse_passed:
        for candidate in (out/'partial_summary.json',out/'summary.json'):
            if candidate.is_file():
                previous=json.loads(candidate.read_text(encoding='utf-8'))
                if previous.get('source_hashes_match') and previous.get('source_hashes')==before:
                    reusable.update({r['case']:r for r in previous['cases'] if r['passed']})
    def case(name):
        # 先前定向系统仿真可能与其它独立用例并行结束；提交该用例前重新核对证据。
        if args.reuse_passed and name not in reusable:
            candidate=out/'partial_summary.json'
            try:
                previous=json.loads(candidate.read_text(encoding='utf-8'))
                if previous.get('source_hashes_match') and previous.get('source_hashes')==before:
                    reusable.update({r['case']:r for r in previous['cases'] if r['passed']})
            except (OSError,json.JSONDecodeError):pass
        if name in reusable:
            print(name,'PASS (unchanged inputs; verified prior run)',flush=True)
            return reusable[name]
        marker,timeout=CASES[name];start=time.monotonic()
        sources=[p for p in src if not(name=='tb_v024_system' and p.name=='hdmi_live_display.v') and not(name=='tb_menu_cdc' and p.name in ('hdmi_clocks.v','hdmi_tx.v'))]
        output=out/(name+'.vvp')
        argv=[str(tool/'iverilog.exe'),'-g2012','-I',str(ROOT/'src'),'-I',str(ROOT/'tests'),'-s',name,'-o',str(output),*map(str,sources),str(ROOT/'tests'/(name+'.v'))]
        if name=='tb_midi_keyboard':argv.append(str(ROOT/'tests/tb_midi_support.v'))
        c=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
        (out/(name+'_compile.log')).write_text(c.stdout+c.stderr,encoding='utf-8')
        log='';exit_code=None
        if not c.returncode:
            try:
                p=subprocess.run([str(tool/'vvp.exe'),str(output)],cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=timeout)
                log=p.stdout+p.stderr;exit_code=p.returncode
            except subprocess.TimeoutExpired as exc:log='TIMEOUT '+str(exc)
        (out/(name+'_run.log')).write_text(log,encoding='utf-8')
        result={'case':name,'compile_argv':argv,'compile_exit':c.returncode,'run_exit':exit_code,
            'passed':not c.returncode and exit_code==0 and marker in log and 'FATAL:' not in log,
            'elapsed_seconds':round(time.monotonic()-start,3),'timeout_seconds':timeout,'pass_marker':marker}
        print(name,'PASS' if result['passed'] else 'FAIL',result['elapsed_seconds'],flush=True)
        return result
    with ThreadPoolExecutor(max_workers=max(1,min(args.workers,3))) as pool:
        results=list(pool.map(case,selected))
    report={'cases':results,'all_passed':all(c['passed'] for c in results),
        'full_suite':set(selected)==set(CASES),'source_hashes':before,'source_hashes_match':before==hashes(),
        'hardware_programmed':False,'physical_validation':False}
    report['all_passed'] &= report['source_hashes_match']
    (out/('summary.json' if report['full_suite'] else 'partial_summary.json')).write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print('V024_REGRESSION_PASS' if report['all_passed'] else 'V024_REGRESSION_FAIL',len(results),flush=True)
    if not report['all_passed']:raise SystemExit(1)
if __name__=='__main__':main()
