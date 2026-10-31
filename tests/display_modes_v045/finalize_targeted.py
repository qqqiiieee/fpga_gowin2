"""Consolidate already-run directed checks; no additional simulation or build.

Use after the requested narrowing of a running preview sweep. Every required
PASS marker and full PPM is checked; missing/failing checks never become passed.
"""
from pathlib import Path
import hashlib
import json
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE/'tool_deps'))


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out=Path(sys.argv[1]).resolve()
    required={
        'generate_v045_display_text':'V045_DISPLAY_TEXT_CHECK_PASS',
        'generate_ui_text':'UI_TEXT_CHECK_PASS',
        'generate_ui_lookup':'UI_LOOKUP_CHECK_PASS',
        'generate_v036_font':'V036_FONT_CHECK_PASS',
        'cdc':'V045_CDC_PASS','legacy_cdc':'V035_DISPLAY_CDC_PASS',
        'pixels_targeted':'V045_PIXELS_PASS',
        'live_fixed':'V045_CAPTURE_PASS','live_auto':'V045_CAPTURE_PASS',
        'live_wait':'V045_CAPTURE_PASS','library_1':'V045_CAPTURE_PASS'}
    records=[];pending=[]
    for name,marker in required.items():
        path=out/(name+'.log')
        log=path.read_text(encoding='utf-8') if path.exists() else ''
        ok=marker in log and 'FATAL:' not in log
        records.append(dict(name=name,passed=ok,log=str(path),
                            markers=[line for line in log.splitlines() if '_PASS' in line]))
        if not ok:pending.append(name)
    frozen=json.loads((HERE/'source_freeze.json').read_text())
    assert frozen['files']=={p:sha(ROOT/p) for p in frozen['files']},'Frozen source changed'
    report=dict(passed=not pending,state='running' if pending else 'complete',pending=pending,
        scope='Directed V045 display checks; four previews only, per user request',
        tests=records,source_sha256=frozen['files'],source_frozen=True,
        cdc_reused_from=str(HERE/'results/20261031T102627_343943Z'),
        font_validation=dict(legacy_hanzi=166,new_hanzi=8,bytes=8192,
                             native_glyph_log=str(HERE/'native_glyph_check.txt')),
        production_character_rom_words=4096,production_status_bits=401,
        cancelled_optional_checks=['unbounded full literal sweep','visualization full frame','diagnostic full frame','owned-page full frame'],
        cancellation_reason='User requested bounded directed checks; these pages remain covered by the 18-scenario pixel test',
        gowin_run=False,synthesis_run=False,flashed=False,physical_hdmi_verified=False)
    if not pending:
        from PIL import Image,ImageDraw
        previews=['live_fixed','live_auto','live_wait','library_1']
        sheet=Image.new('RGB',(1280,1024),(11,16,28));draw=ImageDraw.Draw(sheet)
        for n,name in enumerate(previews):
            path=out/(name+'.ppm')
            assert path.stat().st_size==len(b'P6\n640 480\n255\n')+640*480*3,(name,'Incomplete raster')
            im=Image.open(path).convert('RGB');assert im.size==(640,480)
            im.save(out/(name+'.png'))
            x=n%2*640;y=n//2*512
            draw.text((x+12,y+8),name,fill=(226,232,240));sheet.paste(im,(x,y+32))
        sheet.save(out/'preview_contact_sheet.png')
        report['previews']=[str(out/(n+'.png')) for n in previews]
        report['literal_oracle']=json.loads((out/'targeted_pixel_metrics.json').read_text())
        report['preview']=str(out/'preview_contact_sheet.png')
        # Check only compiled dependencies; top/guide/ESP remain parent-owned.
        import importlib.util,re
        spec=importlib.util.spec_from_file_location('display_runner',HERE/'run_tests.py')
        runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
        deps=set(runner.DISPLAY);todo=list(deps)
        while todo:
            rel=todo.pop()
            if rel.endswith(('.v','.vh')):
                for ref in re.findall(r'"(src/[^"\r\n]+)"',(out/'snapshot'/rel).read_text(encoding='utf-8')):
                    if (out/'snapshot'/ref).is_file() and ref not in deps:deps.add(ref);todo.append(ref)
        assert all(sha(ROOT/p)==sha(out/'snapshot'/p) for p in deps),'Display dependency changed'
        report['dependency_sha256']={p:sha(ROOT/p) for p in sorted(deps)}
        frozen['pending']=[];frozen['validation_report']=str(out/'targeted_report.json')
        (HERE/'source_freeze.json').write_text(json.dumps(frozen,indent=2)+'\n',encoding='utf-8')
    (out/'targeted_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (HERE/'latest_report.json').write_text(json.dumps(dict(report_path=str(out/'targeted_report.json'),**report),
        ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('V045_TARGETED_PASS' if not pending else 'V045_TARGETED_PENDING '+','.join(pending),flush=True)
    return bool(pending)


if __name__=='__main__':raise SystemExit(main())
