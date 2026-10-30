"""补齐三个新HDL文件的Gowin工程条目，禁止隐式依赖IDE自动发现。"""
from pathlib import Path
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
def main():
    path=ROOT/'instrument_handoff.gprj';tree=ET.parse(path);files=tree.getroot().find('FileList')
    names={f.attrib['path'].replace('\\','/') for f in files};changed=False
    for name in ('piano_roll_score.v','piano_roll_guide.v','piano_roll_renderer.v'):
        source='src/'+name;assert (ROOT/source).is_file()
        if source not in names:
            ET.SubElement(files,'File',path=source,type='file.verilog',enable='1');changed=True
    if changed:tree.write(path,encoding='utf-8',xml_declaration=True)
    print('V024_PROJECT_READY')
if __name__=='__main__':main()
