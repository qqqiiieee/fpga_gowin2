"""Compile the actual ESP job scheduler against a deterministic UART/FPGA model.
Not a replacement for ESP32 Flash/Wi-Fi/serial hardware testing.
"""
from pathlib import Path
import re,subprocess,json,hashlib
R=Path(__file__).resolve().parents[1];O=R/'tests/v041_scheduler_results';O.mkdir(exist_ok=True)
source=(R/'esp32_phone/v041_runtime.h').read_text(encoding='utf8')
def function(name):
 start=source.index('inline void '+name+'('); opening=source.index('{',start); depth=1;at=opening+1
 while depth:
  depth+=(source[at]=='{')-(source[at]=='}');at+=1
 return source[start:at]
job=re.search(r'struct Job \{[^\n]+\} job;',source)[0]
code=r'''
#include <cstdio>
#include <vector>
#include <array>
#include <string>
#include "../../esp32_phone/v041_core.h"
static uint32_t now=1000;uint32_t millis(){return now;}
static unsigned checks=0;static int failed=0;
#define CHECK(x) do{++checks;if(!(x)){printf("FAIL line %d: %s\n",__LINE__,#x);return 1;}}while(0)
struct FakeBridge{bool inflight=false,queued=false,linked=true;uint8_t seq=0;uint32_t lastAck=1000,panicFailed=0,panicApplied=0;struct{bool active=false;}telemetry;bool ready(){return linked;}void tick(uint32_t t){lastAck=t;}void abortTelemetry(){telemetry.active=false;}bool panic(uint32_t& r){r=++panicApplied;return true;}}bridge;
std::vector<std::array<uint8_t,12>> packets;
void uartSend(const uint8_t* p,size_t,void*){std::array<uint8_t,12>a;for(int i=0;i<12;++i)a[i]=p[i];packets.push_back(a);}
v041::Score score;v041::Mapping map,activeMap;v041::Rpc rpc;
bool sink(const uint8_t*,size_t,void*){return true;}v041::Audio audio(sink,nullptr);
bool activeScoreKnown=false,activeMapKnown=false,activeMapEnabled=false,persistMap=false,recordFileOpen=false,recordValidated=false,stopRequested=false,crcKnown=false,remoteBusy=false;
uint32_t nextJob=0,recordStarted=0,lastAudioAt=1000,remoteStopAt=0,fpgaCrc=0;unsigned recordSeconds=30,stopAttempts=0;
void usbResult(uint8_t,uint8_t,uint32_t){}
'''+job+'\n'+'\n'.join(function(n) for n in ['newJob','failJob','finishJob','issue','consumeAck','scheduler'])+r'''
// Protocol model retains inactive staging on error, matching FPGA RTL. Actual
// FPGA state/mapping is separately exercised with real UART in tb_state_midi_real.
int stage=0,failOp=-1,failAfter=-1;unsigned seenWrite=0;std::vector<unsigned> ops;
void respond(const std::array<uint8_t,12>& q){
 unsigned op=q[5];ops.push_back(op);uint8_t status=0;uint32_t reply=0;
 if(op==0)reply=0x10007;
 else if(op==19){if(stage==1)stage=0;else if(stage!=0)status=3;}
 else if(op==37){if(stage==2)stage=0;else if(stage!=0)status=3;}
 else if(op==16||op==32){if(stage)status=3;else stage=op==16?1:2;}
 else if(op==17||op==33||op==34||op==35){if(!stage)status=6;else ++seenWrite;}
 else if(op==18||op==36){if(!stage)status=6;}
 if(int(op)==failOp&&(failAfter<0||seenWrite>=unsigned(failAfter))){status=3;failOp=-1;}
 if(!status&&(op==18||op==36))stage=0;
 uint8_t b[12]={0x5A,0xA5,1,q[3],uint8_t(status?0x21:0x20),uint8_t(op),status};v041::put32(b+7,reply);b[11]=phone::checksum(b);if(!rpc.receive(b))failed=1;
}
bool run(){unsigned n=0;while(job.running&&n++<1000){auto before=packets.size();scheduler(now++);if(packets.size()>before)respond(packets.back());}return !job.running;}
int main(){
 const char* e="";score.count=1;score.events[0]={60,96,0,4};CHECK(score.build(e));CHECK(map.validate(e));
 newJob(1,score.total+2);CHECK(run()&&job.ok&&stage==0&&activeScoreKnown);CHECK(ops[0]==0&&ops[1]==19&&ops[2]==37&&ops[3]==16&&ops.back()==18);CHECK(job.progress==job.total);
 ops.clear();failOp=36;newJob(2,138);CHECK(run()&&!job.ok&&job.error==3&&stage==2&&!activeMapKnown);CHECK(ops[1]==19&&ops[2]==37&&ops.back()==36);
 ops.clear();newJob(2,138);CHECK(run()&&job.ok&&activeMapKnown&&stage==0);CHECK(ops[1]==19&&ops[2]==37&&ops[3]==32);CHECK(job.progress==138);
 // Abort in score upload, then upload a mapping, not just retry same job type.
 failOp=17;newJob(1,score.total+2);CHECK(run()&&!job.ok&&stage==1);
 ops.clear();newJob(2,138);CHECK(run()&&job.ok&&stage==0);CHECK(ops[1]==19&&ops[2]==37);
 failOp=33;newJob(2,138);CHECK(run()&&!job.ok&&stage==2);
 ops.clear();newJob(1,score.total+2);CHECK(run()&&job.ok&&stage==0);CHECK(ops[1]==19&&ops[2]==37);
 // A bad cleanup RPC is not silently treated as a successful upload.
 failOp=0;newJob(1,score.total+2);CHECK(run()&&!job.ok);
 CHECK(!failed);printf("V041_SCHEDULER_PASS checks=%u interrupted_upload_recovery=1 cross_type_retry=1 atomic_commit_busy_retry=1 actual_functions=1\n",checks);return 0;
}
'''
(O/'scheduler.cpp').write_text(code,encoding='utf8')
cmd=f'''@echo off
setlocal
set VSCMD_SKIP_SENDTELEMETRY=1
call "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /Fe:"{O/'scheduler.exe'}" /Fo:"{O/'scheduler.obj'}" "{O/'scheduler.cpp'}"
if errorlevel 1 exit /b 1
"{O/'scheduler.exe'}"
'''
(O/'run.cmd').write_text(cmd,encoding='ascii');p=subprocess.run(['cmd','/d','/c',str(O/'run.cmd')],capture_output=True,text=True,errors='replace',timeout=45,cwd=R)
log=p.stdout+p.stderr;print(log);(O/'run.log').write_text(log,encoding='utf8')
d={'passed':p.returncode==0 and 'V041_SCHEDULER_PASS' in log,'runtime_sha256':hashlib.sha256((R/'esp32_phone/v041_runtime.h').read_bytes()).hexdigest(),'scope':'Actual scheduler functions extracted verbatim; modeled legacy heartbeat and FPGA command reply, no hardware.'};(O/'results.json').write_text(json.dumps(d,indent=2));assert d['passed']
