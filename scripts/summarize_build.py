"""从真实Gowin布局布线报告生成资源、时序及固件身份记录。

Logic和CLS分别统计；不能用LUT减少数代替实际布局余量。
仅分析文件，不连接下载器，不把编译成功写成实机验证通过。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def summarize(project: Path) -> dict:
    pnr = project / 'impl/pnr'
    report = (pnr / 'instrument_handoff.rpt.txt').read_text(encoding='utf-8', errors='replace')
    timing = (pnr / 'instrument_handoff.tr').read_text(encoding='utf-8', errors='replace')
    firmware = pnr / 'instrument_handoff.fs'
    fs_text = firmware.read_text(encoding='ascii', errors='replace')
    resources, capacities = {}, {}
    for name in ['Logic', 'Register', 'CLS', 'BSRAM', 'DSP']:
        match = re.search(r'^\s*' + name + r'\s*\|\s*([\d.]+)/([\d.]+)', report, re.M)
        if not match:
            raise ValueError(f'Missing resource: {name}')
        resources[name], capacities[name] = map(float, match.groups())
    violations = {}
    for name in ['Setup', 'Hold']:
        match = re.search(r'<Numbers of ' + name + r' Violated Endpoints>:\s*(\d+)', timing)
        if not match:
            raise ValueError(f'Missing timing summary: {name}')
        violations[name] = int(match[1])
    fmax = {name: float(actual) for name, actual in re.findall(
        r'^\s*\d+\s+(clk27|serial126|pixel25_2)\s+[\d.]+\(MHz\)\s+([\d.]+)\(MHz\)', timing, re.M)}
    assert len(fmax) == 3, 'Missing constrained clock results'
    match = re.search(r'//UserCode:\s*(0x[0-9A-Fa-f]+)', fs_text)
    assert match, 'Missing UserCode in bitstream header'
    hierarchy = {}
    xml = project / 'impl/gwsynthesis/instrument_handoff_syn_rsc.xml'
    for node in ET.parse(xml).getroot().iter('SubModule'):
        if node.attrib.get('name') in ['u_dashboard', 'synth', 'u_alloc', 'u_telemetry']:
            hierarchy[node.attrib['name']] = node.attrib
    input_path = project / 'validation/build_input_hashes.json'
    inputs = json.loads(input_path.read_text(encoding='utf-8'))
    mismatches = [name for name, digest in inputs.items()
                  if not (project / name).is_file()
                  or hashlib.sha256((project / name).read_bytes()).hexdigest() != digest]
    assert not mismatches, f'Build input changed: {mismatches}'
    return {
        'project': str(project), 'resources': resources, 'capacities': capacities,
        'utilization_percent': {name: round(resources[name] / capacities[name] * 100, 3) for name in resources},
        'timing_violations': violations, 'fmax_mhz': fmax, 'synthesis_hierarchy': hierarchy,
        'firmware': str(firmware), 'usercode': match[1].upper().replace('0X', '0x'),
        'firmware_sha256': hashlib.sha256(firmware.read_bytes()).hexdigest(),
        'input_hashes_verified': True, 'hardware_programmed': False,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=ROOT)
    parser.add_argument('--baseline', type=Path, default=ROOT / 'validation/baseline_v019/build_summary.json')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    data = summarize(args.project)
    if args.baseline.is_file():
        before = json.loads(args.baseline.read_text(encoding='utf-8'))
        data['baseline'] = before
        data['resource_reduction'] = {name: before['resources'][name] - value
                                      for name, value in data['resources'].items()}
    destination = args.output or args.project / 'validation/build_summary.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: data[key] for key in ['resources', 'timing_violations', 'fmax_mhz', 'usercode']}, ensure_ascii=True))


if __name__ == '__main__':
    main()
