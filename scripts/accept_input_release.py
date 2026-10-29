"""对V019最终输入、离线测试和文档做发布门禁；不访问实体设备。"""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil
from summarize_build import summarize

ROOT=Path(__file__).resolve().parents[1]
def read(path):return json.loads(path.read_text(encoding='utf-8'))
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def check_hashes(values):
    bad=[n for n,h in values.items() if not (ROOT/n).is_file() or sha(ROOT/n)!=h]
    assert not bad,bad

def main():
    build=summarize(ROOT)
    assert build['timing_violations']=={'Setup':0,'Hold':0}
    inputs=read(ROOT/'validation/build_input_hashes.json');check_hashes(inputs)
    records=[];counts={}
    for name in ['midi_agent.json','optical_agent.json']:
        d=read(ROOT/'validation'/name)
        assert d['status'].upper()=='PASS' and d['source_stable'],name
        check_hashes(d['sources_sha256'])
        records.append(name);counts[name.removesuffix('_agent.json')+'_driver_groups']=len(d['tests'])
    inherited=Path('D:/Gowin_project/instrument_touch_20261024/validation/touch_driver_agent.json')
    d=read(inherited);assert d['status'].upper()=='PASS';check_hashes(d['sources_sha256'])
    shutil.copy2(inherited,ROOT/'validation/touch_driver_inherited.json')
    counts['touch_driver_groups_inherited_unchanged']=len(d['tests']);records.append('touch_driver_inherited.json')
    reports={};metadata_drift={}
    for folder in ['final_verified_regression','touch_all_inputs_verified','zero_release_verified']:
        candidates=list((ROOT/'validation'/folder).glob('run_*/results.json'))
        assert len(candidates)==1,(folder,candidates)
        p=candidates[0];d=read(p);assert d['status']=='PASS',folder
        assert d['snapshot_hashes_verified_at_finish'],folder
        # 所有实际构建输入必须与测试冻结输入一致；映射JSON仅为说明，不参与DUT。
        for n,h in inputs.items():
            posix=n.replace('\\','/')
            if posix.startswith('src/'):
                assert d['source_hashes'].get(posix)==h,(folder,n)
        drift=[n for n,h in d['source_hashes'].items() if (ROOT/n).is_file() and sha(ROOT/n)!=h]
        allowed={'assets/midi_tiny_mapping.json','tests/Python/test_input_monitor.py'}
        if folder=='final_verified_regression':allowed.add('tests/tb_touch_integration.v')
        assert set(drift)<=allowed,(folder,drift)
        metadata_drift[folder]=drift
        reports[folder]=p.relative_to(ROOT/'validation').as_posix();records.append(reports[folder])
    base=read(ROOT/'validation'/reports['final_verified_regression'])
    assert base['counts']=={'PASS':12,'EXPECTED_FAILURE_PASS':1,'FAIL':0},base['counts']
    counts['system_positive_runs']=14;counts['system_expected_negative']=1
    review=read(ROOT/'validation/midi_optical_integration_review.json');assert review['status']=='PASS'
    check_hashes(review['source_provenance']['source_sha256']);records.append('midi_optical_integration_review.json')
    host=read(ROOT/'validation/host_input_tests.json');assert host['status']=='PASS';check_hashes(host['source_hashes'])
    counts['host_unittest_methods']=28;records.append('host_input_tests.json')
    phase=read(ROOT/'validation/phase_ram_candidate/result.json');assert phase['status']=='PASS'
    assert phase['candidate_sha256']==sha(ROOT/'src/wavetable_synth.v')
    counts['phase_equivalence_modes']=4;counts['phase_fault_injection_negative']=3;records.append('phase_ram_candidate/result.json')
    docs=read(ROOT/'validation/docs_final_followup.json');assert docs['status']=='PASS';check_hashes(docs['final_hashes'])
    records.append('docs_final_followup.json')
    result={'status':'PASS','completed_utc':datetime.now(timezone.utc).isoformat(),'version':'V019',
        'scope':'software preparation, source correspondence, offline simulations, documentation, real Gowin PnR; no hardware',
        'production_input_hashes':inputs,'counts':counts,'evidence':records,
        'non_dut_changes_since_simulation':metadata_drift,
        'non_dut_change_explanation':'midi_tiny_mapping.json is descriptive documentation only; the host input_monitor test received a standalone import-path fix and was rerun with final hashes in host_input_tests.json. Later touch_all_inputs_verified supersedes the earlier touch bench with MIDI+OPTICAL+PHASE_RAM+source tags all enabled. No production RTL/ROM/CST drift.',
        'firmware_sha256':build['firmware_sha256'],'usercode':build['usercode'],
        'hardware_programmed':False,'physical_tests':'not performed; first-use touch calibration, power, cabling, beam idle polarity, real MIDI chain and audio/HDMI remain pending',
        'material_limits':['GVS analog encoding only validates one key at a time','runtime touch calibration resets to HEX defaults after reset; persistence requires rebuild','CLS 96.441 percent, further expansion needs optimization','existing synthesis warnings preserved in full log; physical reset and calibration behavior to verify','four-digit frequency display saturates 9999 for high MIDI notes']}
    (ROOT/'validation/acceptance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':result['status'],'counts':counts,'verified_build_inputs':len(inputs),'usercode':build['usercode']},ensure_ascii=False))

if __name__=='__main__':main()
