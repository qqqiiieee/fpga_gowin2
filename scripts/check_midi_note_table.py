"""独立核对MIDI0..127的DDS查表取整；--fix只修正与最近整数不符的常数。"""
from pathlib import Path
import argparse,math,re
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--fix',action='store_true');a=ap.parse_args()
    path=ROOT/'src/note_table.v';text=path.read_text(encoding='utf-8');changes=[]
    def convert(m):
        n=int(m[1]);v=int(m[2]);expected=math.floor(440*2**((n-69)/12)*2**24/93750+0.5)
        if v!=expected:changes.append((n,v,expected))
        return m[0].replace('24\'d'+str(v),'24\'d'+str(expected)) if a.fix else m[0]
    new=re.sub(r"7'd(\d+):phase_inc=24'd(\d+);",convert,text)
    assert len(re.findall(r"7'd\d+:phase_inc=24'd\d+;",text))==128
    if a.fix:path.write_text(new,encoding='utf-8')
    print('MIDI_NOTE_TABLE', 'FIXED' if a.fix else ('PASS' if not changes else 'FAIL'),changes)
    if changes and not a.fix:raise SystemExit(1)
if __name__=='__main__':main()
