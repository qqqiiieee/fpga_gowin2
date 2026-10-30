"""Current release checks, offline only; --ui and --web add rendering/browser checks."""
from pathlib import Path
import argparse,json,subprocess,sys
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui',action='store_true',help='Include literal-text pixels and coherent status CDC')
    parser.add_argument('--web',action='store_true',help='Include phone browser tests; npm dependencies and Chromium required')
    args=parser.parse_args()
    commands=[[sys.executable,'scripts/verify_release.py']]
    for name in ['generate_ui_text','generate_ui_lookup','generate_odd_half_rom','generate_dual_timbres','generate_touch_centers']:
        commands.append([sys.executable,'scripts/'+name+'.py','--check'])
    commands.extend([[sys.executable,'scripts/check_midi_note_table.py'],
                     [sys.executable,'scripts/run_v034_tests.py'],
                     [sys.executable,'tests/phone_bridge/run_native.py']])
    if args.ui:
        commands.extend([[sys.executable,'scripts/run_hdmi_hybrid_tests.py'],
                         [sys.executable,'scripts/run_four_key_ui_render.py']])
    if args.web:commands.append(['node','tests/phone_bridge/web_ui.test.cjs'])
    results=[]
    for cmd in commands:
        print('CHECK', ' '.join(cmd),flush=True)
        r=subprocess.run(cmd,cwd=ROOT)
        results.append({'command':cmd,'exit_code':r.returncode})
        if r.returncode:break
    out=ROOT/'validation';out.mkdir(exist_ok=True)
    report={'version':'V034','passed':len(results)==len(commands) and all(r['exit_code']==0 for r in results),
            'tests':results,'with_ui':args.ui,'with_web':args.web,
            'finished_utc':datetime.now(timezone.utc).isoformat(),'hardware_accessed':False}
    (out/'release_checks.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('RELEASE_CHECKS_'+('PASS' if report['passed'] else 'FAIL'),flush=True)
    return 0 if report['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
