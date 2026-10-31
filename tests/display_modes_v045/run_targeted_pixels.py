"""Finish a bounded pixel check using the already compiled frozen snapshot.

Keeps all 18 public scenarios, 32768 deterministically shuffled literal pixels,
and explicit blanking boundaries for every scenario. No rebuild or synthesis.
"""
from pathlib import Path
import json,os,subprocess,sys

HERE=Path(__file__).resolve().parent
TOOL=Path('D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin')
out=Path(sys.argv[1]).resolve()
with (out/'literal_pixels.txt').open(encoding='ascii') as f:
    rows=[next(f) for _ in range(32768)]
scenes=json.loads((out/'scenes.json').read_text())
assert {int(r.split()[3]) for r in rows}==set(range(len(scenes)))
for scene in scenes:
    for x,y in [(640,0),(799,479),(0,480),(640,524),(1023,1023)]:
        rows.append(f'{x} {y} 1 {scene["id"]} 000000\n')
    rows.append(f'40 30 0 {scene["id"]} 000000\n')
vectors=out/'targeted_literal_pixels.txt';vectors.write_text(''.join(rows),encoding='ascii')
env=dict(os.environ,PATH=str(TOOL)+os.pathsep+os.environ.get('PATH',''))
p=subprocess.run([str(TOOL/'vvp.exe'),str(out/'pixels.vvp'),
    f'+SCENARIOS={(out/"scenarios.hex").as_posix()}',f'+COUNT={len(scenes)}',
    f'+VECTORS={vectors.as_posix()}'],cwd=out/'snapshot',env=env,capture_output=True,text=True,timeout=180)
log=p.stdout+p.stderr
(out/'pixels_targeted.log').write_text(log,encoding='utf-8')
print(log,flush=True)
assert p.returncode==0 and 'V045_PIXELS_PASS' in log and 'FATAL:' not in log
(out/'targeted_pixel_metrics.json').write_text(json.dumps(dict(vectors=len(rows),scenarios=len(scenes),
    rationale='User requested bounded directed checks instead of a broader pixel sweep'),indent=2)+'\n')
