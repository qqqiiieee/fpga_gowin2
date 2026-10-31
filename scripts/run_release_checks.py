"""Portable V047 release smoke checks. No build, programming, serial or network."""
from pathlib import Path
from datetime import datetime, timezone
import json, subprocess, sys, shutil
from toolchain import find_icarus

ROOT=Path(__file__).resolve().parents[1]

def main():
    tools=find_icarus()
    node=shutil.which('node')
    if not node:raise SystemExit('Node.js is required for current phone JSON checks')
    out=ROOT/'validation/release_smoke';out.mkdir(parents=True,exist_ok=True)
    cases={
        'modes':['guide_chord_modes.v'],
        'events':['guide_chord_events.v','voice_allocator.v'],
        'score_pixels':['phone_extension_state.v','piano_roll_guide.v',
                        'piano_roll_renderer.v','custom_score_ram.v','piano_roll_score.v']}
    commands=[[sys.executable,'scripts/verify_release.py']]
    for name,sources in cases.items():
        binary=out/(name+'.vvp')
        commands.extend([[str(tools.iverilog),'-g2012','-Wall','-s','tb_'+name,
            '-o',str(binary),*['src/'+f for f in sources],
            'tests/chords_v047/tb_'+name+'.v'],[str(tools.vvp),str(binary)]])
    commands.append([node,'scripts/check_score_examples.cjs'])
    results=[]
    for cmd in commands:
        p=subprocess.run(cmd,cwd=ROOT,env=tools.environment(),capture_output=True,
                         text=True,encoding='utf-8',errors='replace',timeout=120)
        results.append({'command':cmd,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
        print(p.stdout[-1800:],end='',flush=True)
        if p.returncode:
            print(p.stderr[-2400:],file=sys.stderr);break
    passed=len(results)==len(commands) and all(x['exit_code']==0 for x in results)
    report={'version':'V047','passed':passed,'scope':'identity, three chord RTL benches, current phone score codec',
            'hardware_accessed':False,'full_project_built':False,'tests':results,
            'finished_utc':datetime.now(timezone.utc).isoformat()}
    (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('RELEASE_SMOKE_'+('PASS' if passed else 'FAIL'))
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
