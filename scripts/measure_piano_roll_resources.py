"""Isolated Gowin synthesis A/B; no production project/build outputs touched.

Uses two frozen input snapshots under tests/piano_roll_resources. Reports the
actual tool resources; synthesis estimates do not replace full production PnR.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
TOOL=Path('D:/Gowin_V1.9.12.04_x64_win/Gowin/Gowin_V1.9.12.04_x64/IDE/bin/gw_sh.exe')
FILES=['src/hdmi_compact_dashboard.v','src/hdmi_ui_font.v','src/piano_roll_renderer.v',
       'src/piano_roll_score.v','src/hdmi_status_cdc.v','tests/piano_roll_resource_top.v',
       'src/hdmi_ui_text.vh','src/ui_font.hex']


def main():
    out=ROOT/'tests/piano_roll_resources';out.mkdir(exist_ok=True)
    before={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in FILES}
    reports=[]
    def write_report():
        same=before=={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in FILES}
        (out/'summary.json').write_text(json.dumps(dict(source_hashes=before,source_hashes_match=same,
            reports=reports,synthesis_only=True,hardware_programmed=False,
            measured_delta_available=len(reports)==2 and all(r['exit']==0 for r in reports)),indent=2)+'\n',encoding='utf-8')
        return same
    for mode in ['off','on']:
        snap=out/mode;snap.mkdir(exist_ok=True)
        for name in FILES:
            dest=snap/name;dest.parent.mkdir(exist_ok=True)
            shutil.copy2(ROOT/name,dest)
        project=ET.Element('Project')
        ET.SubElement(project,'Template').text='FPGA'
        ET.SubElement(project,'Version').text='5'
        ET.SubElement(project,'Device',name='GW2A-18C',pn='GW2A-LV18PG256C8/I7').text='gw2a18c-011'
        filelist=ET.SubElement(project,'FileList')
        for name in FILES:
            if name.endswith('.v'):
                ET.SubElement(filelist,'File',path=name,type='file.verilog',enable='1')
        ET.ElementTree(project).write(snap/'resource.gprj',encoding='utf-8',xml_declaration=True)
        (snap/'synth.tcl').write_text('cd [file dirname [file normalize [info script]]]\n'
            'open_project resource.gprj\nset_option -top_module piano_roll_resource_'+mode+
            '\nrun syn\nexit\n',encoding='utf-8')
        started=time.monotonic()
        with (out/(mode+'.log')).open('wb') as log:
            run=subprocess.run([str(TOOL),'synth.tcl'],cwd=snap,stdout=log,stderr=subprocess.STDOUT,timeout=300)
        report=dict(mode=mode,exit=run.returncode,elapsed_seconds=round(time.monotonic()-started,3),
                    files=[str(p.relative_to(ROOT)) for p in (snap/'impl').rglob('*rsc*')])
        reports.append(report)
        write_report()
        print(report,flush=True)
        if run.returncode:
            raise RuntimeError((out/(mode+'.log')).read_text(encoding='utf-8',errors='replace')[-5000:])
    same=write_report()
    assert same,'Sources changed; rerun comparison'


if __name__=='__main__':main()
