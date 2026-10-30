"""仅同步V021的PMOD2文档勘误；校验原固件及CST，绝不重打包固件。"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import hashlib
import json
import re
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT.parent / '乐器版本'
RELEASE = STORE / '2026-10-30_114635_V021_MIDI主奏_电容屏控_无手机_20261030'
CANONICAL = ROOT.parent / '接线图/2026-10-30_V021_电容屏控完整接线'
WIRES = ROOT / 'docs/V021_接线图'
FW_HASH = 'c59627066feab3eddb85006bd4764232e00062b8eaa0fc3736806ffd53cefc53'
REVISION = '2026-10-30_R2_PMOD2背面焊点定位'


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    # 发布前先证明：这次确实只有文档变化，未挪动任何信号或复用针脚。
    assert sha(RELEASE / 'instrument_v021.fs') == FW_HASH
    assert sha(ROOT / 'impl/pnr/instrument_handoff.fs') == FW_HASH
    assert sha(ROOT / 'src/multi_tone.cst') == sha(RELEASE / 'source/src/multi_tone.cst')
    new = read(WIRES / '接线表.json')
    old = read(RELEASE / '接线图/接线表.json')
    assert new['nets'] == old['nets'] and new['pin_contract'] == old['pin_contract']
    assert read(WIRES / '接线核查.json')['pages'] == 8
    rows = new['pmod2_back_photo_view']
    assert [[x[0] for x in row] for row in rows] == [
        ['E15', 'A15', 'A14', 'C12', 'GND', '3V3'],
        ['D14', 'B14', 'B13', 'B12', 'GND', '3V3']]
    assert {p: b for row in rows for b, p, role in row} == {
        1: '3V3', 2: '3V3', 3: 'GND', 4: 'GND', 5: 'B12', 6: 'C12',
        7: 'B13', 8: 'A14', 9: 'B14', 10: 'A15', 11: 'D14', 12: 'E15'}
    for svg in WIRES.glob('*.svg'):
        ET.fromstring(svg.read_text(encoding='utf-8'))
    for target in (RELEASE / '接线图', RELEASE / 'source/docs/V021_接线图', CANONICAL):
        shutil.copytree(WIRES, target, dirs_exist_ok=True)
    for name in ('generate_v021_wiring.py', 'generate_v021_notes.py', 'package_v021.py', Path(__file__).name):
        shutil.copy2(ROOT / 'scripts' / name, RELEASE / 'source/scripts' / name)
    for name in ('V021_使用与架构说明.html', 'V021_架构与AI交接.txt'):
        shutil.copy2(ROOT / 'docs' / name, RELEASE / 'source/docs' / name)
        shutil.copy2(ROOT / 'docs' / name, RELEASE / name)
    p = RELEASE / 'V021_使用与架构说明.html'
    p.write_text(p.read_text(encoding='utf-8').replace('V021_接线图/完整接线图.html', '接线图/完整接线图.html')
                 .replace('../validation/build_summary.json', '验证/build_summary.json'), encoding='utf-8')
    p = RELEASE / 'source/docs/V021_使用与架构说明.html'
    p.write_text(p.read_text(encoding='utf-8').replace('../validation/build_summary.json', '../../验证/build_summary.json'), encoding='utf-8')
    p = RELEASE / '版本入口.html'
    p.write_text(p.read_text(encoding='utf-8').replace('完整接线图（7页）', '完整接线图（8页）'), encoding='utf-8')

    stamp = datetime.now(timezone(timedelta(hours=8))).isoformat()
    record = {'id': REVISION, 'date_beijing': stamp, 'type': 'documentation_only',
        'changes': ['新增第8页PMOD2背面焊点定位，与用户照片同方向',
                    '明确B14=第二列下针/J6.9、A15=第二列上针/J6.10、B13=第三列下针/J6.7',
                    '更正PMOD0功能表的方向说明；补充I2S页定位指引',
                    '完整图、PDF、逐线数据、使用与交接说明同步更新为8页'],
        'firmware_changed': False, 'cst_changed': False, 'needs_reprogramming': False,
        'firmware_sha256': FW_HASH, 'visual_review': '8页已渲染检查，无裁切、重叠或替代字符',
        'hardware_continuity_tested_by_agent': False, 'sources': new['pmod2_sources'],
        'source_revision_note': '3713原理图核对球号和J6信号；3709 PCB只交叉核对孔位方向，用户整板版本未据此确认',
        'photo': r'C:\Users\31989\AppData\Local\Temp\codex-clipboard-14113b53-c32e-40ff-9746-18d6a6e49466.jpg'}
    evidence = ROOT / 'validation/pmod2_wiring_r2.json'
    write(evidence, record)
    shutil.copy2(evidence, RELEASE / '验证/PMOD2接线文档修订.json')
    info = read(RELEASE / '版本信息.json')
    info['documentation_revisions'] = [r for r in info.get('documentation_revisions', []) if r['id'] != REVISION] + [record]
    write(RELEASE / '版本信息.json', info)
    p = RELEASE / '版本说明.txt'
    value = p.read_text(encoding='utf-8-sig')
    if REVISION not in value:
        value += '\n文档修订：' + REVISION + '\n时间：' + stamp + '（北京时间）\n新增PMOD2背面焊点定位，第8页。球号、源码约束及固件不变，无需重新烧录。\n'
    p.write_text(value, encoding='utf-8-sig')
    qa = read(RELEASE / '验证/发布核验.json')
    qa.update(pdf_pages=8, visual_review='R2: all8 rendered pages visually inspected',
              document_revision=REVISION, firmware_sha256_matches=True)
    write(RELEASE / '验证/发布核验.json', qa)

    # 检查发布入口及源码说明所有本地href；URL片段不作为文件路径。
    for file in (RELEASE / '版本入口.html', RELEASE / 'V021_使用与架构说明.html',
                 RELEASE / 'source/docs/V021_使用与架构说明.html', CANONICAL / '完整接线图.html'):
        for href in re.findall(r'href="([^"]+)"', file.read_text(encoding='utf-8')):
            if href.startswith(('http:', 'https:', '#')):
                continue
            assert (file.parent / href.split('#')[0]).exists(), (file, href)
    for target in (RELEASE / '接线图', RELEASE / 'source/docs/V021_接线图', CANONICAL):
        for source in WIRES.rglob('*'):
            if source.is_file():
                assert sha(source) == sha(target / source.relative_to(WIRES))
    manifest = {str(p.relative_to(RELEASE)): sha(p) for p in RELEASE.rglob('*')
                if p.is_file() and p.name != '文件校验.json'}
    write(RELEASE / '文件校验.json', manifest)
    assert sha(RELEASE / 'instrument_v021.fs') == FW_HASH
    print(json.dumps({'status': 'V021_WIRING_R2_PASS', 'pages': 8, 'files': len(manifest),
                      'firmware_changed': False, 'canonical': str(CANONICAL)}, ensure_ascii=True))


if __name__ == '__main__':
    main()
