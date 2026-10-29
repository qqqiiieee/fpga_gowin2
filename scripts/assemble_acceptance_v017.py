"""汇总本版实际回归、来源哈希及真实Gowin时序；不对硬件作验收结论。"""
from pathlib import Path
import hashlib
import json
from summarize_build import summarize

ROOT=Path(__file__).resolve().parents[1]

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def verify_source(report, selected):
    # UI/core快照也可能包含并行新增测试，所有已记录的生产源码/资产必须逐项一致。
    checked=0
    non_elaborated_differences={}
    for name,digest in report['source_hashes'].items():
        if name.startswith(('src/','assets/')):
            actual=hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
            if actual!=digest:
                # 兼容路径修复仅影响instrument_audio。旧UI/独立算法记录可以复用的
                # 前提是Icarus实际展开的文件表证明此模块根本没参与该用例。
                assert name=='src/instrument_audio.v',name
                for test_name in selected:
                    test=report['tests'][test_name]
                    compiled=Path(test['directory'])/'simulation.vvp'
                    file_table=compiled.read_text(encoding='utf-8',errors='replace').split(':file_names')[-1]
                    assert 'instrument_audio.v' not in file_table,(test_name,name)
                    (compiled.parent/'elaborated_files.txt').write_text(
                        'Exported from Icarus simulation.vvp :file_names table.\n'
                        'Confirms instrument_audio.v is not elaborated by this unchanged test.\n'
                        +file_table,encoding='utf-8')
                    non_elaborated_differences[test_name]=name
            checked+=1
    assert checked>0
    return {"checked":checked,"unchanged_elaborated_sources":True,"non_elaborated_differences":non_elaborated_differences}

def main():
    core_path=sorted((ROOT/'validation/core_regression').glob('run_*/results.json'))[-1]
    ui_path=sorted((ROOT/'validation/timbre2_ui_regression').glob('run_*/results.json'))[-1]
    dual=read(ROOT/'validation/dual_timbre_agent/latest_results.json')
    dual_path=Path(dual['run'])/'results.json'
    asset=read(ROOT/'validation/dual_asset_tests.json')
    core=read(core_path);ui=read(ui_path)
    final_core_path=sorted((ROOT/'validation/core_audio_compat_final').glob('run_*/results.json'))[-1]
    final_menu_path=sorted((ROOT/'validation/menu_top_compat_final').glob('run_*/results.json'))[-1]
    final_core=read(final_core_path);final_menu=read(final_menu_path)
    assert final_core['status']==final_menu['status']=='PASS'
    replaced=set(final_core['tests'])|set(final_menu['tests'])
    records=[('core',core_path,core,[n for n in core['tests'] if n not in replaced]),
             ('keypad_ui',ui_path,ui,list(ui['tests'])),
             ('core_audio_final',final_core_path,final_core,list(final_core['tests'])),
             ('menu_top_final',final_menu_path,final_menu,list(final_menu['tests'])),
             ('dual_audio',dual_path,dual,list(dual['tests']))]
    assert set(core['tests'])==({n for n in core['tests'] if n not in replaced}|replaced)
    assert len(core['tests'])==22
    counts={'rtl_pass':0,'expected_negative_rejected':0,'asset_unit_tests':asset['tests']}
    cases={}; hash_checks={}
    for label,path,data,selected in records:
        if label!='core':assert data['status']=='PASS',str(path)
        hash_checks[label]=verify_source(data,selected)
        for name in selected:
            record=data['tests'][name]
            assert record['status'] in ['PASS','EXPECTED_FAILURE_PASS'],(label,name)
            if record['status']=='PASS':counts['rtl_pass']+=1
            else:counts['expected_negative_rejected']+=1
            cases[label+'/'+name]=record['status']
    assert dual['live_inputs_unchanged'] and dual['baseline_unchanged']
    assert len(dual['mutations'])==2
    for name,record in dual['mutations'].items():
        assert record['status']=='EXPECTED_FAILURE',record
        counts['expected_negative_rejected']+=1
    assert asset['status']=='PASS'
    for name,digest in asset['source_hashes'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
    assert read(ROOT/'validation/timbre2_ui_agent.json')['status']=='PASS'
    review=read(ROOT/'validation/dual_timbre_review.json')
    assert review['status'] in ['PASS','PASS_WITH_NOTES'],review
    assert read(ROOT/'validation/review_resolution.json')['status']=='PASS'
    current=summarize(ROOT)
    assert current['timing_violations']=={'Setup':0,'Hold':0}
    # 既有接线和时钟约束必须精确不变。
    before=Path(read(ROOT/'validation/baseline_v016/build_summary.json')['project'])
    for name in ['multi_tone.cst','matrix_clock.sdc']:
        assert (ROOT/'src'/name).read_bytes()==(before/'src'/name).read_bytes(),name
    counts['total_positive']=counts['rtl_pass']+counts['asset_unit_tests']
    production=read(ROOT/'validation/build_input_hashes.json')
    result={'status':'PASS','version':'V017','counts':counts,'cases':cases,
            'source_hash_checks':hash_checks,'production_input_hashes':production,
            'result_directories':[str(path.parent.relative_to(ROOT)).replace('\\','/') for _,path,_,_ in records],
            'result_files':{label:str(path.relative_to(ROOT)).replace('\\','/') for label,path,_,_ in records},
            'resources':current['resources'],'timing_violations':current['timing_violations'],
            'superseded_core_tests':sorted(replaced),'supersession_reason':'Final compatibility-path build reran every case elaborating instrument_audio; unaffected cases retain exact elaborated inputs.',
            'source_constraints_unchanged':True,'hardware_programmed':False,
            'validation_scope':'Digital RTL and generator guard tests only; new0/1 is compared with frozen V016 old1/7. Old 16-timbre pixel/audio identity is intentionally superseded.'}
    (ROOT/'validation/acceptance_v017.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('V017_ACCEPTANCE_PASS',json.dumps(counts))

if __name__=='__main__':
    main()
