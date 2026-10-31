"""Compile production portable Score codec and compare all JS fixture words.

JS independently decodes each word against the JSON events; this stage checks
the actual ESP C++ codec agrees for rests, count-in, onsets, chord/mono branches.
No device/network access. Uses the installed Microsoft compiler.
"""
from pathlib import Path
import json, subprocess, hashlib
R=Path(__file__).resolve().parents[2]
T=Path(__file__).resolve().parent
vectors=json.loads((T/'js.json').read_text(encoding='utf8'))['results']
lines=['#include <cassert>','#include <cstdio>','#include "../../esp32_phone/v041_core.h"',
       'int main(){const char* error="";unsigned checks=0;']
for result in vectors:
    o=result['source']
    lines += ['{v041::Score s;',f's.bpm={o["bpm"]};s.count={len(o["events"])};']
    if 'total_beats' in o:lines += [f's.melodyQuarters={int(o["total_beats"]*4)};']
    for i,e in enumerate(o['events']):
        p=e.get('pitches',[e.get('pitch')]);d=[n-p[0] for n in p[1:]];d+= [0]*(3-len(d))
        lines += [f's.events[{i}]={{{p[0]},{e["velocity"]},{round(e["start"]*4)},{round(e["duration"]*4)},{{{",".join(map(str,d))}}}}};']
    words=','.join(str(x)+'u' for x in result['words'])
    lines += [f'uint32_t expected[]={{{words}}};',
              f'assert(s.build(error));assert(s.total=={result["total"]});assert(s.sum=={result["sum"]});',
              'for(unsigned q=0;q<s.total;++q){++checks;assert(s.words[q]==expected[q]);}',
              'for(unsigned q=s.total;q<256;++q)assert(s.words[q]==0);','}']
lines += ['{v041::Score s;s.count=1;s.events[0]={41,100,0,4,{12,19,31}};assert(s.build(error)&&s.hasChords);',
          's.events[0].offsets[1]=12;assert(!s.build(error));',
          's.events[0].offsets[1]=0;assert(!s.build(error));',
          's.events[0].offsets[1]=19;s.events[0].pitch=42;assert(!s.build(error));',
          's.events[0].pitch=41;s.events[0].offsets[2]=32;assert(!s.build(error));}',
          'std::printf("V047_CPP_SCORE_PASS quarters=%u\\n",checks);return 0;}']
(T/'native.cpp').write_text('\n'.join(lines),encoding='utf8')
cmd=f'''@echo off
setlocal
set VSCMD_SKIP_SENDTELEMETRY=1
call "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /Fe:"{T / 'native.exe'}" /Fo:"{T / 'native.obj'}" "{T / 'native.cpp'}"
if errorlevel 1 exit /b 1
"{T / 'native.exe'}"
'''
(T/'native.cmd').write_text(cmd,encoding='ascii')
p=subprocess.run(['cmd','/d','/c',str(T/'native.cmd')],cwd=R,capture_output=True)
log=(p.stdout+p.stderr).decode('utf8',errors='replace');print(log)
(T/'native.log').write_text(log,encoding='utf8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
(T/'native_result.json').write_text(json.dumps(dict(passed=p.returncode==0,hardware_accessed=False,
    source_sha256={str(p.relative_to(R)):sha(p) for p in [R/'esp32_phone/v041_core.h',T/'js.json',T/'native.cpp']},
    exit_code=p.returncode),indent=2),encoding='utf8')
raise SystemExit(p.returncode)
