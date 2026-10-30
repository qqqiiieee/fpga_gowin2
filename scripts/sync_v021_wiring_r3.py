"""同步BMV51M001实物丝印勘误；保留接收待验证状态，不改固件/约束。"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import hashlib
import json
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT.parent / '乐器版本'
RELEASE = STORE / '2026-10-30_114635_V021_MIDI主奏_电容屏控_无手机_20261030'
CANONICAL = ROOT.parent / '接线图/2026-10-30_V021_电容屏控完整接线'
WIRES = ROOT / 'docs/V021_接线图'
FW_HASH = 'c59627066feab3eddb85006bd4764232e00062b8eaa0fc3736806ffd53cefc53'
REVISION = '2026-10-30_R3_BMV51M001实物RX_TX勘误_接收实测通过'


def read(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))


def write(p, v):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(v, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    assert sha(RELEASE / 'instrument_v021.fs') == FW_HASH
    assert sha(ROOT / 'impl/pnr/instrument_handoff.fs') == FW_HASH
    assert sha(ROOT / 'src/multi_tone.cst') == sha(RELEASE / 'source/src/multi_tone.cst')
    new, old = read(WIRES / '接线表.json'), read(RELEASE / '接线图/接线表.json')
    assert new['pin_contract'] == old['pin_contract']
    assert len(new['nets']) == len(old['nets']) == 37
    for i, (a, b) in enumerate(zip(new['nets'], old['nets'])):
        if i not in (8, 9):
            assert a == b, (i, a, b)
        else:
            assert a[:2] == b[:2], (i, a, b)
    assert new['nets'][8][1] == 'T8 / midi_rx'
    assert read(WIRES / '接线核查.json')['pages'] == 9
    for svg in WIRES.glob('*.svg'):
        ET.fromstring(svg.read_text(encoding='utf-8'))

    stamp = datetime.now(timezone(timedelta(hours=8))).isoformat()
    test_dir = Path((ROOT.parent / 'midi_rx_probe_20261030/last_rewire_test_path.txt').read_text(encoding='utf-8-sig').strip())
    test_record = read(test_dir / '诊断与恢复记录.json')
    summary = test_record['summary']
    assert test_record['production_restore']['success'] is True
    assert summary['valid_note_events_seen'] and summary['query_errors'] == 0
    assert summary['new_counts_during_monitor']['frame_errors'] == 0
    photos = [r'C:\Users\31989\Downloads\IMG_20261030_151107.jpg',
              r'C:\Users\31989\Downloads\IMG_20261030_151059.jpg']
    record = {'id': REVISION, 'date_beijing': stamp, 'type': 'documentation_only',
        'model_confirmed_from_photos': 'BEST MODULES BMV51M001 V1.0',
        'physical_order_from_nc_end': ['NC', 'RX', 'TX', 'VDD', 'GND'],
        'official_table_order_from_nc_end': ['NC', 'TX', 'RX', 'VDD', 'GND'],
        'test_connection': {'physical_TX_middle_pad': 'FPGA T8 / midi_rx',
                            'VDD': '3.3V', 'GND': 'GND', 'NC': 'unconnected', 'RX': 'unconnected'},
        'status': 'physical middle TX -> T8 verified with live MIDI bytes and Note On/Off events',
        'continuity_tested': False, 'rewiring_confirmed': True,
        'midi_received_after_rewiring': True, 'live_summary': summary,
        'live_evidence_directory': str(test_dir), 'production_v021_restored': True,
        'firmware_changed': False, 'cst_changed': False, 'needs_reprogramming': False,
        'firmware_sha256': FW_HASH, 'pages': 9, 'photos': photos,
        'sources': ['https://www.bestmodulescorp.com/en/amfile/file/download/file/2107/product/1316/',
                    'https://www.bestmodulescorp.com/en/amfile/file/download/file/2100/product/1316/'],
        'changes': ['增加第9页实物丝印与资料差异、断电改线及验证步骤',
                    '接线表接收器端按实物TX标识；T8及全部FPGA球号不变',
                    '仍保留第8页PMOD2定位；改接TX后已收到有效MIDI字节/音符，零帧错误'],
        'visual_review': 'changed pages 6 and 9 rendered and inspected; all pages checked for text bounds'}
    write(ROOT / 'validation/midi_receiver_wiring_r3.json', record)
    write(WIRES / 'MIDI实物勘误与验证状态.json', record)
    for target in (RELEASE / '接线图', RELEASE / 'source/docs/V021_接线图', CANONICAL):
        shutil.copytree(WIRES, target, dirs_exist_ok=True)
    for name in ('generate_v021_wiring.py', 'generate_v021_notes.py', Path(__file__).name):
        shutil.copy2(ROOT / 'scripts' / name, RELEASE / 'source/scripts' / name)
    for name in ('V021_使用与架构说明.html', 'V021_架构与AI交接.txt'):
        for target in (RELEASE, RELEASE / 'source/docs'):
            shutil.copy2(ROOT / 'docs' / name, target / name)
    for p, link, build in [
        (RELEASE / 'V021_使用与架构说明.html', '接线图/完整接线图.html', '验证/build_summary.json'),
        (RELEASE / 'source/docs/V021_使用与架构说明.html', 'V021_接线图/完整接线图.html', '../../验证/build_summary.json')]:
        p.write_text(p.read_text(encoding='utf-8').replace('V021_接线图/完整接线图.html', link)
                     .replace('../validation/build_summary.json', build), encoding='utf-8')
    p = RELEASE / '版本入口.html'
    p.write_text(p.read_text(encoding='utf-8').replace('完整接线图（8页）', '完整接线图（9页）'), encoding='utf-8')
    write(RELEASE / '验证/MIDI接线实物勘误_R3.json', record)
    for src in photos:
        shutil.copy2(src, RELEASE / '验证' / Path(src).name)
    shutil.copytree(test_dir, RELEASE / '验证' / test_dir.name, dirs_exist_ok=True)
    info = read(RELEASE / '版本信息.json')
    info['documentation_revisions'] = [r for r in info.get('documentation_revisions', []) if not r['id'].startswith('2026-10-30_R3_')] + [record]
    info['hardware_midi_input_verified'] = True
    write(RELEASE / '版本信息.json', info)
    p = RELEASE / '版本说明.txt'
    value = p.read_text(encoding='utf-8-sig')
    if REVISION not in value:
        value += '\n文档修订：' + REVISION + '\n北京时间：' + stamp + '\n实物从NC端起为NC/RX/TX/VDD/GND，与资料RX/TX相反。中间实物TX接T8，45秒收到3459字节、Note On 41/Off 40、帧错误0。已恢复V021，输入链路通过；音频仍待验收。9页图及说明已同步；固件/约束不变。\n'
    p.write_text(value, encoding='utf-8-sig')
    qa = read(RELEASE / '验证/发布核验.json')
    qa.update(pdf_pages=9, document_revision=REVISION,
              midi_receiver_physical_pin_validation='physical TX -> T8 live MIDI input verified; 3459 bytes, On41/Off40, frame errors0')
    write(RELEASE / '验证/发布核验.json', qa)
    for target in (RELEASE / '接线图', RELEASE / 'source/docs/V021_接线图', CANONICAL):
        for src in WIRES.rglob('*'):
            if src.is_file():
                assert sha(src) == sha(target / src.relative_to(WIRES))
    manifest = {str(p.relative_to(RELEASE)): sha(p) for p in RELEASE.rglob('*')
                if p.is_file() and p.name != '文件校验.json'}
    write(RELEASE / '文件校验.json', manifest)
    assert sha(RELEASE / 'instrument_v021.fs') == FW_HASH
    print(json.dumps({'status': 'V021_WIRING_R3_SYNC_PASS', 'pages': 9,
                      'firmware_changed': False, 'receiver_electrical_validation': 'live MIDI passed'}, ensure_ascii=True))


if __name__ == '__main__':
    main()
