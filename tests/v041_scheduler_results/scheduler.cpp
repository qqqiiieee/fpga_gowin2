
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
struct Job {uint32_t id=0,started=0,panicRevision=0;uint8_t kind=0,action=0,rawOp=0,rawData[5]{},cleanup=0;int step=0;unsigned progress=0,total=0;bool running=false,waiting=false,cap=false,panic=false,ok=false;uint8_t error=0,status=0;uint32_t reply=0;const char* message="空闲";} job;
inline void newJob(uint8_t kind,unsigned total){job=Job();job.id=++nextJob;job.kind=kind;job.total=total;job.running=true;job.started=millis();job.message="等待FPGA能力确认";}
inline void failJob(const char* reason,uint8_t code=0){if(job.kind==8)usbResult(0x21,code?code:10,job.reply);job.running=job.waiting=false;job.ok=false;job.message=reason;job.error=code;rpc.inflight=rpc.done=false;if((job.kind>=3&&job.kind<=5)||(job.kind==8&&(job.rawOp==48||job.rawOp==49))){audio.fail(reason);audio.active=false;stopRequested=true;}}
inline void finishJob(){job.running=job.waiting=false;job.ok=true;job.progress=job.total;job.message="FPGA已确认";}
inline void issue(uint8_t op,const uint8_t data[5],uint32_t now){if(op==48)remoteBusy=true;if(op==49){remoteStopAt=now;++stopAttempts;}rpc.begin(bridge.seq++,op,data,now);job.waiting=true;uartSend(rpc.frame,12,nullptr);}
inline void consumeAck(){
 if(!job.running||!job.waiting||!rpc.done)return;
 job.waiting=false;rpc.done=false;job.status=rpc.status;job.reply=rpc.reply;
 // A previous interrupted upload may have left either inactive staging bank
 // open. Cancel BOTH types before a new upload. BUSY on one cancel can mean
 // the other staging type is open; neither cancel changes the active music.
 if(job.cap&&(job.kind==1||job.kind==2)&&job.cleanup<2){
  if(rpc.ok||rpc.error==3){++job.cleanup;return;}
  failJob("清理未完成的上传失败，请检查FPGA连接",rpc.error);return;
 }
 if(job.kind==8)usbResult(rpc.ok?0x20:0x21,rpc.status,rpc.reply);
 if(!rpc.ok){failJob(rpc.error==3?"FPGA忙：请松开琴键/踏板，或明确选择Panic后重试":"扩展RPC失败/超时；未显示成功",rpc.error);return;}
 if(!job.cap){if(rpc.reply!=0x00010007u){failJob("FPGA扩展能力不匹配");return;}job.cap=true;job.message="正在逐帧写入FPGA";return;}
 ++job.progress;
 if(job.kind==1){if(job.step==0)job.step=1;else if(job.step<=score.total)++job.step;else {activeScoreKnown=true;finishJob();}}
 else if(job.kind==2){if(job.step<137)++job.step;else{activeMap=map;activeMapKnown=true;activeMapEnabled=true;persistMap=true;finishJob();}}
 else if(job.kind==3){if(!recordStarted)recordStarted=millis();lastAudioAt=millis();job.message="FPGA开始实际PCM录音";finishJob();}
 else if(job.kind==4){job.step=1;job.message="等待EOF排空";}
 else if(job.kind==5){fpgaCrc=rpc.reply;crcKnown=true;recordValidated=audio.verify(fpgaCrc);if(recordValidated)finishJob();else failJob(audio.error);}
 else if(job.kind==6)finishJob();
 else if(job.kind==7){activeMap.defaults();activeMapKnown=true;activeMapEnabled=false;persistMap=true;finishJob();}
 else if(job.kind==8){
  if(job.rawOp==48){if(!recordStarted)recordStarted=millis();lastAudioAt=millis();}
  if(job.rawOp==49)stopRequested=false;
  if(job.rawOp==50&&audio.eof&&recordFileOpen){fpgaCrc=rpc.reply;crcKnown=true;recordValidated=audio.verify(fpgaCrc);}
  if(job.rawOp==51)remoteBusy=(rpc.reply&(1u<<30))!=0;
  if(job.rawOp==36)activeMapKnown=false;
  if(job.rawOp==38){activeMap.defaults();activeMapKnown=true;activeMapEnabled=false;persistMap=true;}
  finishJob();
 }
}
inline void scheduler(uint32_t now){
 consumeAck();
 if(audio.active&&recordStarted&&uint32_t(now-recordStarted)>=recordSeconds*1000u)stopRequested=true;
 if(audio.active&&uint32_t(now-lastAudioAt)>3000){audio.fail("音频断线/超过3秒无有效帧");stopRequested=true;}
 if(audio.bad&&audio.active)stopRequested=true;
 if(!job.running&&stopRequested&&remoteBusy&&stopAttempts==0){newJob(4,1);job.cap=true;stopRequested=false;}
 if(audio.eof&&!crcKnown&&!job.running&&recordFileOpen){newJob(5,1);job.cap=true;}
 if(remoteStopAt&&remoteBusy&&uint32_t(now-remoteStopAt)>6000){audio.fail("停止后EOF断线超时");audio.active=false;}
 if(job.running&&job.kind==4&&job.step==1){
  if(audio.eof){finishJob();}
  else if(uint32_t(now-job.started)>6000){failJob("停止后未收到EOF，录音无效");}
 }
 if(rpc.inflight){if(rpc.tick(now))uartSend(rpc.frame,12,nullptr);return;}
 if(bridge.inflight){bridge.tick(now);return;}
 // Legacy ACK heartbeat and explicit parameter/Panic writes remain independent.
 if(bridge.queued||!bridge.ready()||uint32_t(now-bridge.lastAck)>350){bridge.tick(now);if(job.running&&uint32_t(now-job.started)>20000)failJob("FPGA断线，扩展作业未完成");return;}
 if(!job.running||(job.kind==4&&job.step==1)){bridge.tick(now);return;}
 if(bridge.telemetry.active)bridge.abortTelemetry();
 uint8_t d[5]={};
 if(!job.cap){issue(v041::CAP,d,now);return;}
 if((job.kind==1||job.kind==2)&&job.cleanup<2){
  issue(job.cleanup==0?v041::SCORE_CANCEL:v041::MAP_CANCEL,d,now);return;
 }
 if(job.kind==1){
  if(job.step==0){d[0]=score.count;d[1]=uint8_t(score.total);d[2]=uint8_t(score.beatSamples);d[3]=uint8_t(score.beatSamples>>8);d[4]=uint8_t(score.beatSamples>>16);issue(v041::SCORE_BEGIN,d,now);}
  else if(job.step<=score.total){unsigned q=unsigned(job.step-1);d[0]=uint8_t(q);v041::put32(d+1,score.words[q]);issue(v041::SCORE_WRITE,d,now);}
  else{v041::put16(d,score.sum);issue(v041::SCORE_COMMIT,d,now);}
 }else if(job.kind==2){
  if(job.step==0)issue(v041::MAP_BEGIN,d,now);
  else if(job.step<=128){d[0]=uint8_t(job.step-1);d[1]=map.notes[job.step-1];issue(v041::NOTE_WRITE,d,now);}
  else if(job.step<=132){d[0]=uint8_t(job.step-129);d[1]=map.pads[job.step-129];issue(v041::PAD_WRITE,d,now);}
  else if(job.step<=136){d[0]=uint8_t(job.step-133);d[1]=map.cc[job.step-133];issue(v041::CC_WRITE,d,now);}
  else{
   if(job.panic){
    if(!job.panicRevision){if(!bridge.panic(job.panicRevision)){failJob("Panic无法发送");}return;}
    if(bridge.panicFailed==job.panicRevision){failJob("Panic未获FPGA确认");return;}
    if(bridge.panicApplied!=job.panicRevision){bridge.tick(now);return;}
   }
   v041::put16(d,map.sum);issue(v041::MAP_COMMIT,d,now);
  }
 }else if(job.kind==3)issue(v041::REC_START,d,now);
 else if(job.kind==4)issue(v041::REC_STOP,d,now);
 else if(job.kind==5)issue(v041::REC_CRC,d,now);
 else if(job.kind==6){d[0]=job.action;issue(v041::GUIDE_CONTROL,d,now);}
 else if(job.kind==7){
  if(job.panic){if(!job.panicRevision){if(!bridge.panic(job.panicRevision))failJob("Panic无法发送");return;}if(bridge.panicFailed==job.panicRevision){failJob("Panic未确认");return;}if(bridge.panicApplied!=job.panicRevision){bridge.tick(now);return;}}
  issue(v041::MAP_DISABLE,d,now);
 }
 else if(job.kind==8)issue(job.rawOp,job.rawData,now);
}
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
