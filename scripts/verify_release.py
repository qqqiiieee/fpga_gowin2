"""Verify checked-in V034 identities offline; never connect to either board."""
from pathlib import Path
import hashlib,json,sys,xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    m=json.loads((ROOT/'manifest.json').read_text(encoding='utf-8'))
    assert m['version']=='V034', 'Unexpected release manifest'
    assert digest(ROOT/m['firmware_name'])==m['sha256'], 'FPGA binary hash mismatch'
    assert '//UserCode: '+m['usercode'] in (ROOT/m['firmware_name']).read_text(encoding='ascii'), 'FPGA UserCode mismatch'
    for group in (m['build_source_hashes'],m.get('build_configuration_sha256',{}),m['esp32']['source_sha256'],m['esp32']['artifacts_sha256']):
        for name,value in group.items():assert digest(ROOT/name)==value.lower(),name
    for node in ET.parse(ROOT/m['project']).getroot().iter('File'):
        assert (ROOT/node.attrib['path']).is_file(), node.attrib['path']
    checksums=ROOT/'checksums.json'
    if checksums.exists():
        for name,value in json.loads(checksums.read_text(encoding='utf-8'))['sha256'].items():
            target=(ROOT/name).resolve()
            assert target.is_relative_to(ROOT),name
            assert target.is_file() and digest(target)==value,name
    print('RELEASE_IDENTITY_PASS V034 '+m['usercode']+'; FPGA/ESP32/source hashes match; no hardware access')
    return 0
if __name__=='__main__':
    try:raise SystemExit(main())
    except (AssertionError,OSError,KeyError,ValueError) as error:
        print('RELEASE_IDENTITY_FAIL',error,file=sys.stderr);raise SystemExit(1)
