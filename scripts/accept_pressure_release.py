"""V020发布门禁：只接受与本次RTL/ROM/引脚匹配的真实构建和离线证据。"""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json
from summarize_build import summarize
ROOT=Path(__file__).resolve().parents[1]
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def check_hashes(h):
    bad=[n for n,v in h.items() if not (ROOT/n).is_file() or sha(ROOT/n)!=v]
    assert not bad,bad
def main():
    build=summarize(ROOT);assert build['timing_violations']=={'Setup':0,'Hold':0}
    inputs=read(ROOT/'validation/build_input_hashes.json');check_hashes(inputs)
    unit=read(ROOT/'validation/pressure_expression_agent.json')
    assert unit['status']=='PASS' and unit['source_stable'] and unit['frozen_rtl_matches']
    assert len(unit['tests'])==15 and all(t['status']=='PASS' for t in unit['tests'])
    check_hashes(unit['sources_sha256_after'])
    audio=read(ROOT/'validation/pressure_audio_agent.json')
    assert audio['status']=='PASS' and audio['sources_unchanged']
    assert len(audio['tests'])==3 and all(t['status']=='PASS' for t in audio['tests'])
    check_hashes(audio['sources_sha256'])
    system={};non_dut_drift={}
    for folder in ['expression_regression','expression_midi_optical_regression','menu_expression_final','pressure_ui_verified']:
        paths=list((ROOT/'validation'/folder).glob('run_*/results.json'));assert len(paths)==1
        p=paths[0];d=read(p)
        if folder=='expression_regression':
            assert d['status']=='FAIL' and d['counts']=={'PASS':9,'EXPECTED_FAILURE_PASS':0,'FAIL':1},d.get('counts')
            bad=[n for n,t in d['tests'].items() if t['status']!='PASS']
            assert bad==['tb_menu_preview'],bad
            assert 'Independent vector page=3' in d['tests']['tb_menu_preview']['reason']
        else:assert d['status']=='PASS',d.get('counts')
        assert d['snapshot_hashes_verified_at_finish']
        for n,v in inputs.items():
            n=n.replace('\\','/')
            if n.startswith('src/'):assert d['source_hashes'].get(n)==v,(folder,n)
        # 并行worker只新增/修正其自用bench，不属于本轮标准runner编译对象。
        drift=[n for n,v in d['source_hashes'].items() if (ROOT/n).is_file() and sha(ROOT/n)!=v]
        allowed={'tests/tb_pressure_audio_expression.v','tests/tb_pressure_expression.v','assets/menu_layout.json'}
        assert set(drift)<=allowed,(folder,drift)
        non_dut_drift[folder]=drift;system[folder]=p.relative_to(ROOT/'validation').as_posix()
    inherited=read(ROOT/'validation/inherited_evidence.json');assert inherited['status']=='PASS'
    for item in inherited['records']:
        d=read(ROOT/'validation'/item['record'])
        check_hashes(d.get('sources_sha256',d.get('source_hashes',{})))
    docs=read(ROOT/'validation/docs_final_followup.json')
    assert docs['status']=='PASS';check_hashes(docs['source_hashes'])
    log=(ROOT/'validation/gowin_build.log').read_text(encoding='utf-8',errors='replace')
    assert '"pressure_adaptive" instantiated to "pads" is swept' in log
    counts={'pressure_parameter_cases':15,'pressure_black_box_assertions':unit['assertions'],
        'independent_audio_groups':3,'system_regression_passes':sum(read(ROOT/'validation'/n)['counts']['PASS'] for n in system.values()),'inherited_unchanged_evidence_groups':4}
    correction=read(ROOT/'validation/menu_oracle_correction.json')
    assert correction['old_text']=='S13/S14 选择16音色' and correction['new_text']=='S13/S14 选择2音色'
    assert sha(ROOT/'assets/menu_layout.json')==correction['after_sha256']
    correction.update(status='PASS',final_rerun=system['menu_expression_final'])
    (ROOT/'validation/menu_oracle_correction.json').write_text(json.dumps(correction,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    result={'status':'PASS','version':'V020','completed_utc':datetime.now(timezone.utc).isoformat(),
        'production_input_hashes':inputs,'counts':counts,'usercode':build['usercode'],'firmware_sha256':build['firmware_sha256'],
        'evidence':{'pressure':'pressure_expression_agent.json','audio':'pressure_audio_agent.json','system':system,'unchanged':'inherited_evidence.json'},
        'non_dut_bench_changes':non_dut_drift,
        'superseded_menu_case':'Original independent layout text still said 16 timbres; updated specification to required 2 and reran unchanged full menu assertions. No RTL/build input changed. See menu_oracle_correction.json.',
        'hardware_programmed':False,'hardware_tested':False,
        'behavior':'A0 continuous brightness, A1 continuous vibrato depth; no FSR hits. Sliders A2/A3 preserved; MIDI pad drums retained; 32-tone mode isolated.',
        'limits':['global expression shared across voices; not per-key MPE','FSR baseline learned unloaded on startup/reconnect; 16 samples/channel','0..255 ADC-derived controls are not calibrated kg','runtime touch centers still need separate first-use calibration','physical pressure range, hearing effect, headphone noise and HDMI remain unmeasured']}
    (ROOT/'validation/acceptance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':'PASS','counts':counts,'resources':build['resources'],'usercode':build['usercode']},ensure_ascii=False))
if __name__=='__main__':main()
