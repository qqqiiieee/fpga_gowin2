#pragma once
#include <LittleFS.h>
#include <esp_partition.h>
#include "v041_json.h"
#include "wav_view.h"

// UART task owns protocol/core state. HTTP and file writer use short mutex
// sections; no Flash operation runs while holding that mutex.
namespace extension {
// V047: op0 bit3 advertises packed chord words. Only op22 proves guide state;
// an op20/op21 ACK is acceptance, never an echo of the applied setting.
static const uint8_t GUIDE_MODE=21,GUIDE_STATE=22;
static const uint32_t GUIDE_FRESH_MS=3000,GUIDE_REFRESH_MS=1000;
struct GuideCache {
 uint32_t raw=0,updated=0;bool have=false,verified=false;const char* error="尚未读回导奏状态";
 void invalidate(const char* why){verified=false;error=why;}
 bool accept(uint32_t value,uint32_t now){
  if((value&0xFF000000u)||(value&3u)==3u){invalidate("op22状态格式错误");return false;}
  raw=value;updated=now;have=verified=true;error="";return true;
 }
 bool fresh(uint32_t now,bool ready)const{return have&&verified&&ready&&uint32_t(now-updated)<=GUIDE_FRESH_MS;}
 unsigned mode()const{return raw&3u;}unsigned rollSong()const{return (raw>>2)&3u;}
 unsigned selectedSong()const{return (raw>>22)&3u;}
} guide;
static uint32_t guideRefreshAt=0;static bool guideRefreshStarted=false;
inline bool guideKind(uint8_t kind){return kind==6||kind==9||kind==10||kind==11;}
static SemaphoreHandle_t mutex;
static portMUX_TYPE ringMux=portMUX_INITIALIZER_UNLOCKED;
static const unsigned RING_SIZE=16384;
static uint8_t ring[RING_SIZE];static unsigned ringRead=0,ringWrite=0,ringUsed=0;
static uint32_t ringHigh=0,uartHigh=0,maxWriteUs=0,rxErrors=0;
static unsigned rxBudget=1536;
static bool fsReady=false,recordFileOpen=false,recordValidated=false,recordFinished=false,persistMap=false;
static bool stopRequested=false,crcKnown=false,remoteBusy=false;static uint32_t fpgaCrc=0,recordStarted=0,lastAudioAt=0,remoteStopAt=0;static unsigned stopAttempts=0;
static unsigned recordSeconds=30;static const char* storageError="";
static File recordFile;static uint32_t writtenBytes=0;
static v041::Score score;static v041::Mapping map,activeMap;
static bool activeMapKnown=false,activeScoreKnown=false,activeMapEnabled=false;
static String usbReply;
static v041::Rpc rpc;static phone::Parser demux;
struct Job {uint32_t id=0,started=0,panicRevision=0;uint8_t kind=0,action=0,song=3,rawOp=0,rawData[5]{},cleanup=0;int step=0;unsigned progress=0,total=0;bool running=false,waiting=false,cap=false,panic=false,ok=false,requestAccepted=false,stateVerified=false,targetMatch=false;uint8_t error=0,status=0;uint32_t reply=0;const char* message="空闲";} job;
static uint32_t nextJob=0;
inline void lock(){xSemaphoreTake(mutex,portMAX_DELAY);}inline void unlock(){xSemaphoreGive(mutex);}
inline unsigned ringCount(){portENTER_CRITICAL(&ringMux);unsigned n=ringUsed;portEXIT_CRITICAL(&ringMux);return n;}
static bool sink(const uint8_t* b,size_t n,void*){
 portENTER_CRITICAL(&ringMux);if(n>RING_SIZE-ringUsed){portEXIT_CRITICAL(&ringMux);return false;}
 for(size_t i=0;i<n;++i){ring[ringWrite]=b[i];ringWrite=(ringWrite+1)%RING_SIZE;}ringUsed+=n;if(ringUsed>ringHigh)ringHigh=ringUsed;portEXIT_CRITICAL(&ringMux);return true;
}
static v041::Audio audio(sink,nullptr);
inline bool recording(){return recordFileOpen&&!recordFinished;}
inline void newJob(uint8_t kind,unsigned total){job=Job();job.id=++nextJob;job.kind=kind;job.total=total;job.running=true;job.started=millis();job.message="等待FPGA能力确认";if(kind==1||(guideKind(kind)&&kind!=11))guide.invalidate("设置已入队，等待op22实际状态");}
inline void usbResult(uint8_t result,uint8_t status,uint32_t reply){usbReply=String("{\"usb_ext\":{\"op\":")+String(job.rawOp)+",\"result\":"+String(result)+",\"status\":"+String(status)+",\"reply\":"+String(reply)+"}}\n";}
inline void failJob(const char* reason,uint8_t code=0){if(guideKind(job.kind)&&!job.stateVerified)guide.invalidate(reason);if(job.kind==8)usbResult(0x21,code?code:10,job.reply);job.running=job.waiting=false;job.ok=false;job.message=reason;job.error=code;rpc.inflight=rpc.done=false;if((job.kind>=3&&job.kind<=5)||(job.kind==8&&(job.rawOp==48||job.rawOp==49))){audio.fail(reason);audio.active=false;stopRequested=true;}}
inline void finishJob(){job.running=job.waiting=false;job.ok=true;job.progress=job.total;job.message="FPGA已确认";}
inline void issue(uint8_t op,const uint8_t data[5],uint32_t now){if(op==20||op==GUIDE_MODE||op==18)guide.invalidate("等待op22读回，设置ACK仅代表接受");if(op==GUIDE_STATE){guideRefreshAt=now;guideRefreshStarted=true;}if(op==48)remoteBusy=true;if(op==49){remoteStopAt=now;++stopAttempts;}rpc.begin(bridge.seq++,op,data,now);job.waiting=true;uartSend(rpc.frame,12,nullptr);}
inline void guideAck(){
 if(job.kind!=11&&job.step==0){job.requestAccepted=true;job.step=1;job.message="请求已接受，等待op22实际状态";return;}
 if(!guide.accept(rpc.reply,millis())){failJob("op22状态格式错误",13);return;}
 job.stateVerified=true;
 // Compare stable targets only. A pause toggle/replay may already have moved
 // on by readback: report active/done/hold, never infer those from the action.
 job.targetMatch=job.kind==11||(job.kind==10?guide.mode()==job.action:guide.selectedSong()==job.song);
 if(!job.targetMatch){failJob("已读回实际状态，但模式/选曲与请求不符",12);return;}
 finishJob();job.message=job.kind==11?"已读回导奏实际状态":"请求已接受并读回；播放进度以实际状态为准";
}
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
 if(!job.cap){if(rpc.reply!=0x00010007u && rpc.reply!=0x0001000fu){failJob("FPGA扩展能力不匹配");return;}if(job.kind==1 && score.hasChords && !(rpc.reply&8u)){failJob("和弦曲谱需要FPGA V047，请先升级FPGA");return;}job.cap=true;job.message="正在逐帧写入FPGA";return;}
 ++job.progress;
 if(job.kind==1){if(job.step==0)job.step=1;else if(job.step<=score.total)++job.step;else {activeScoreKnown=true;finishJob();}}
 else if(job.kind==2){if(job.step<137)++job.step;else{activeMap=map;activeMapKnown=true;activeMapEnabled=true;persistMap=true;finishJob();}}
 else if(job.kind==3){if(!recordStarted)recordStarted=millis();lastAudioAt=millis();job.message="FPGA开始实际PCM录音";finishJob();}
 else if(job.kind==4){job.step=1;job.message="等待EOF排空";}
 else if(job.kind==5){fpgaCrc=rpc.reply;crcKnown=true;recordValidated=audio.verify(fpgaCrc);if(recordValidated)finishJob();else failJob(audio.error);}
 else if(guideKind(job.kind))guideAck();
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
 if(!bridge.ready())guide.invalidate("FPGA断线或尚未同步，缓存未验证");
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
 else if(guideKind(job.kind)){
  if(job.kind==11||job.step==1)issue(GUIDE_STATE,d,now);
  else if(job.kind==10){d[0]=job.action;issue(GUIDE_MODE,d,now);}
  else{d[0]=job.action;if(job.kind==9){d[1]=job.song;d[2]=1;}issue(v041::GUIDE_CONTROL,d,now);}
 }
 else if(job.kind==7){
  if(job.panic){if(!job.panicRevision){if(!bridge.panic(job.panicRevision))failJob("Panic无法发送");return;}if(bridge.panicFailed==job.panicRevision){failJob("Panic未确认");return;}if(bridge.panicApplied!=job.panicRevision){bridge.tick(now);return;}}
  issue(v041::MAP_DISABLE,d,now);
 }
 else if(job.kind==8)issue(job.rawOp,job.rawData,now);
}
static void uartTask(void*){
 uint8_t block[1536];
 for(;;){
  lock();unsigned available=fpgaUart.available();if(available>uartHigh)uartHigh=available;
  uint32_t uartErrors=fpgaUart.errors();
  if(uartErrors!=rxErrors){rxErrors=uartErrors;if(recording())audio.fail("UART硬件/RX缓冲溢出");}
  // V042: drain a bounded block in one driver call. Per-byte available()/read()
  // repeatedly takes the UART driver's lock and loses throughput at 1M baud.
  unsigned amount=available<rxBudget?available:rxBudget;
  if(amount>sizeof(block))amount=sizeof(block);
  size_t received=amount?fpgaUart.read(block,amount):0;
  for(unsigned i=0;i<received;++i){
   uint8_t v=block[i];++rawUartRxBytes;uint8_t b[12];uint32_t now=millis();
   bool completing=demux.used==11;uint8_t result=demux.bytes[4];
   if(!demux.feed(uint8_t(v),now,b)){
    if(completing&&(result==0x40||result==0x41)&&recording())audio.fail("音频帧损坏/校验失败");continue;
   }
   if(b[4]==0x40||b[4]==0x41){lastAudioAt=now;if(b[4]==0x40&&audio.active&&!recordStarted)recordStarted=now;if(b[4]==0x41){remoteBusy=false;remoteStopAt=0;if(audio.bad&&!audio.active){audio.eof=true;crcKnown=true;}}audio.receive(b);}
   else if(b[4]==0x20||b[4]==0x21)rpc.receive(b);
   else for(unsigned k=0;k<12;++k)bridge.receive(b[k],now);
  }
  scheduler(millis());if(!bridge.linked){activeMapKnown=false;activeScoreKnown=false;}unlock();
  // UART priority3 and Arduino loop priority1 run on the same core. taskYIELD
  // only offers the CPU to equal/higher priorities: under a continuous stream
  // it starves LittleFS/USB/HTTP. Always block for one RTOS tick. The 8192-byte
  // UART ring absorbs the gap; the 1536-byte batch exceeds one tick's input.
  vTaskDelay(1);
 }
}
inline String jobJson(){
 String s="{\"id\":"+String(job.id)+",\"running\":"+(job.running?"true":"false")+",\"ok\":"+(job.ok?"true":"false")+",\"progress\":"+String(job.progress)+",\"total\":"+String(job.total)+",\"error\":"+String(job.error)+",\"status\":"+String(job.status)+",\"reply\":"+String(job.reply)+",\"message\":\""+job.message+"\"";
 if(guideKind(job.kind))s+=String(",\"request_accepted\":")+(job.requestAccepted?"true":"false")+",\"state_verified\":"+(job.stateVerified?"true":"false")+",\"target_match\":"+(job.targetMatch?"true":"false");
 return s+"}";
}
// Caller holds the same short mutex used by the UART task. GET never sends UART.
inline String guideJson(uint32_t now){
 bool ready=bridge.ready(),fresh=guide.fresh(now,ready),pending=job.running&&guideKind(job.kind);
 String s=String("{\"fresh\":")+(fresh?"true":"false")+",\"verified\":"+(guide.verified&&ready?"true":"false")+",\"stale\":"+(fresh?"false":"true")+",\"age_ms\":"+(guide.have?String(uint32_t(now-guide.updated)):String("null"))+",\"ttl_ms\":"+String(GUIDE_FRESH_MS)+",\"pending\":"+(pending?"true":"false")+",\"job_id\":"+String(pending?job.id:0);
 s+=String(",\"refresh_allowed\":")+(!job.running&&!recording()&&!remoteBusy&&!audio.active&&!stopRequested&&!rpc.inflight&&!bridge.queued&&ready&&(!guideRefreshStarted||uint32_t(now-guideRefreshAt)>=GUIDE_REFRESH_MS)?"true":"false");
 s+=String(",\"error\":\"")+(!ready?"FPGA断线或尚未同步":guide.error)+"\"";
 const char* names[]={"raw","mode","roll_song","active","done","practice_hold","external_suspend","step","expected_note","expected_valid","selected_song"};
 const uint32_t values[]={guide.raw,guide.mode(),guide.rollSong(),(guide.raw>>4)&1u,(guide.raw>>5)&1u,(guide.raw>>6)&1u,(guide.raw>>7)&1u,(guide.raw>>8)&63u,(guide.raw>>14)&127u,(guide.raw>>21)&1u,guide.selectedSong()};
 for(unsigned i=0;i<11;++i){s+=String(",\"")+names[i]+"\":";if(!guide.have)s+="null";else if((i>=3&&i<=6)||i==9)s+=values[i]?"true":"false";else s+=String(values[i]);}
 return s+"}";
}
// Atomic admission: no guide job is inserted during recording, draining or an
// existing job. Explicit refreshes are rate limited; there is no idle UART poll.
inline int enqueueGuide(uint8_t kind,uint8_t song,uint8_t action,uint32_t now){
 if(!bridge.ready())return 503;
 if(job.running||recording()||remoteBusy||audio.active||stopRequested||rpc.inflight||bridge.queued)return 409;
 if(kind==11&&guideRefreshStarted&&uint32_t(now-guideRefreshAt)<GUIDE_REFRESH_MS)return 429;
 newJob(kind,kind==11?1:2);job.song=song;job.action=action;
 guideRefreshAt=now;guideRefreshStarted=true;return 202;
}
inline unsigned maxSeconds(){if(!fsReady)return 0;size_t available=LittleFS.totalBytes()-LittleFS.usedBytes();if(LittleFS.exists("/last.wav")){File f=LittleFS.open("/last.wav","r");available+=f.size();f.close();}if(available<=65580)return 0;unsigned s=unsigned((available-65580)/31250);return s>30?30:s;}
inline String recordingJson(){
 String s="{\"fs_ready\":"+String(fsReady?"true":"false")+",\"saved_available\":"+String(fsReady&&LittleFS.exists("/last.wav")?"true":"false")+",\"max_seconds\":"+String(maxSeconds())+",\"state\":\"";
 lock();s+=recordFinished?(recordValidated?"complete":"invalid"):(recordFileOpen?(audio.eof?"finalizing":"recording"):"idle");
 s+="\",\"valid\":"+String(recordFinished&&recordValidated?"true":"false")+",\"samples\":"+String(audio.samples)+",\"eof_count\":"+String(audio.count)+",\"frames\":"+String(audio.frames)+",\"drops\":"+String(audio.drops)+",\"local_crc\":"+String(audio.finalCrc())+",\"fpga_crc\":"+String(fpgaCrc)+",\"seconds\":"+String(audio.samples/15625.0,4)+",\"error\":\""+(audio.bad?audio.error:storageError)+"\",\"uart_rx_high\":"+String(uartHigh)+",\"ring_high\":"+String(ringHigh)+",\"max_flash_write_us\":"+String(maxWriteUs)+",\"rx_errors\":"+String(rxErrors)+",\"rx_budget\":"+String(rxBudget)+"}";unlock();return s;
}
inline void sendJson(const String& s,int code=200){headers();server.send(code,"application/json; charset=utf-8",s);}
inline bool bodyLimit(unsigned limit){if(server.header("Content-Type")!="application/json"||!server.hasArg("plain")||server.arg("plain").length()>limit){jsonError(413,"需要限长application/json正文");return false;}return true;}
inline bool canConfigure(){lock();bool ok=!job.running&&!recording()&&!remoteBusy&&bridge.ready();unlock();if(!ok)jsonError(409,"作业/录音忙或FPGA尚未同步");return ok;}
inline bool saveText(const char* path,const String& text){String tmp=String(path)+".tmp";File f=LittleFS.open(tmp,"w");if(!f)return false;bool ok=f.print(text)==text.length();f.close();if(!ok){LittleFS.remove(tmp);return false;}return LittleFS.rename(tmp,path);}
inline void jobAccepted(){lock();String s=jobJson();unlock();sendJson(s,202);}
inline void guideSubmit(uint8_t kind){
 if(!bodyLimit(128))return;
 const char* error="";cJSON* o=v041::parse(server.arg("plain"),128,error);int song=3,action=0;
 const char* const controlKeys[]={"song","action"};const char* const modeKeys[]={"mode"};const char* const legacyKeys[]={"action"};
 bool ok=o&&(kind==11?v041::keys(o,nullptr,0):kind==10?(v041::keys(o,modeKeys,1)&&v041::integer(v041::item(o,"mode"),0,2,action)):(v041::keys(o,kind==6?legacyKeys:controlKeys,kind==6?1:2)&&v041::integer(v041::item(o,"action"),0,3,action)&&(kind==6||v041::integer(v041::item(o,"song"),0,3,song))));
 if(o)cJSON_Delete(o);
 if(!ok){jsonError(422,"导奏字段非法：song/action须0..3整数，mode须0..2整数；刷新只接受空对象");return;}
 lock();int code=enqueueGuide(kind,uint8_t(song),uint8_t(action),millis());String response=code==202?jobJson():String();unlock();
 if(code!=202){jsonError(code,code==429?"刷新过频，请至少间隔1秒":code==503?"FPGA尚未同步":"作业/录音忙，请稍后刷新或重试");return;}
 sendJson(response,202);
}
inline void scoreSubmit(bool fromSaved){
 if(!canConfigure())return;if(!fsReady){jsonError(503,"LittleFS未初始化");return;}
 String text;if(fromSaved){File f=LittleFS.open("/score.json","r");if(!f){jsonError(404,"没有已上传曲谱");return;}if(f.size()>16384){f.close();jsonError(413,"已存曲谱过大");return;}text=f.readString();f.close();}
 else{if(!bodyLimit(16384))return;text=server.arg("plain");}
 v041::Score candidate;const char* error="";if(!v041::scoreJson(text,candidate,error)){jsonError(422,error);return;}
 if(!fromSaved&&!saveText("/score.json",text)){jsonError(507,"曲谱保存失败，FPGA未修改");return;}
 lock();score=candidate;newJob(1,score.total+2);unlock();jobAccepted();
}
inline void mappingSubmit(bool defaults){
 if(!canConfigure())return;v041::Mapping candidate;bool panic=false,disabled=defaults;const char* error="";
 if(!defaults){if(!bodyLimit(4096))return;if(!v041::mapJson(server.arg("plain"),candidate,panic,error,&disabled)){jsonError(422,error);return;}}
 else{if(!bodyLimit(128))return;cJSON* o=v041::parse(server.arg("plain"),128,error);const char* const allowed[]={"panic_before_commit"};bool ok=o&&v041::keys(o,allowed,1);if(ok){cJSON* p=v041::item(o,"panic_before_commit");ok=!p||cJSON_IsBool(p);panic=cJSON_IsTrue(p);}if(o)cJSON_Delete(o);if(!ok){jsonError(422,"默认恢复只接受panic_before_commit布尔字段");return;}if(!candidate.validate(error)){jsonError(422,error);return;}}
 if(!fsReady){jsonError(503,"LittleFS未初始化，不能保存映射");return;}
 lock();map=candidate;newJob(disabled?7:2,disabled?1:138);job.panic=panic;unlock();jobAccepted();
}
inline bool prepareRecording(unsigned seconds,const char*& error){
 unsigned available=maxSeconds();if(!fsReady||unsigned(seconds)>available){error="LittleFS空间不足，请按max_seconds缩短录音或初始化存储";return false;}
 if(ESP.getFreeHeap()<32768||ESP.getMaxAllocHeap()<8192){error="内部RAM不足，未启动录音";return false;}
 // This API explicitly replaces the single previous recording, as the UI states.
 LittleFS.remove("/last.wav");LittleFS.remove("/recording.tmp");LittleFS.remove("/record.json");
 recordFile=LittleFS.open("/recording.tmp","w");uint8_t h[44];v041::wavHeader(h,0);
 if(!recordFile||recordFile.write(h,44)!=44){recordFile.close();error="录音文件无法创建";return false;}
 lock();portENTER_CRITICAL(&ringMux);ringRead=ringWrite=ringUsed=0;ringHigh=0;portEXIT_CRITICAL(&ringMux);
 audio.reset();writtenBytes=0;recordFileOpen=true;recordFinished=recordValidated=crcKnown=stopRequested=false;stopAttempts=0;remoteStopAt=0;fpgaCrc=0;recordStarted=0;lastAudioAt=millis();recordSeconds=unsigned(seconds);storageError="";maxWriteUs=0;unlock();return true;
}
inline void startRecording(){
 if(!bodyLimit(256)||!canConfigure())return;const char* error="";cJSON* o=v041::parse(server.arg("plain"),256,error);int seconds=0;
 bool valid=o&&v041::integer(v041::item(o,"seconds"),1,30,seconds);if(o)cJSON_Delete(o);
 if(!valid){jsonError(422,"seconds须为1..30整数");return;}
 if(!prepareRecording(unsigned(seconds),error)){jsonError(507,error);return;}
 lock();newJob(3,1);unlock();jobAccepted();
}
inline void fileService(){
 // UART task continues to drain the 8192-byte driver RX during Flash operations.
 if(recordFileOpen&&!recordFinished){
  uint8_t block[1024];unsigned n=0;portENTER_CRITICAL(&ringMux);n=ringUsed>sizeof(block)?sizeof(block):ringUsed;for(unsigned i=0;i<n;++i){block[i]=ring[ringRead];ringRead=(ringRead+1)%RING_SIZE;}ringUsed-=n;portEXIT_CRITICAL(&ringMux);
  if(n){uint32_t before=micros();size_t w=recordFile.write(block,n);uint32_t took=micros()-before;if(took>maxWriteUs)maxWriteUs=took;writtenBytes+=w;if(w!=n){lock();audio.fail("LittleFS写入失败/空间耗尽");stopRequested=true;unlock();}}
  lock();bool finish=(crcKnown||(!audio.active&&audio.bad))&&ringCount()==0;bool valid=recordValidated&&!audio.bad&&audio.eof&&writtenBytes==audio.count*2;uint32_t count=audio.count;unlock();
  if(finish){
   // V046: NEVER rewrite the beginning of this large LittleFS CTZ file.
   // On V045 a 30s header rewrite copied the remaining file during flush and
   // crashed inside lfs_alloc (IntegerDivideByZero). Keep the 44-byte reserved
   // prefix untouched; HTTP/USB overlay the exact WAV header when reading.
   bool ok=valid;recordFile.flush();recordFile.close();
   if(ok){File check=LittleFS.open("/recording.tmp","r");ok=check&&check.size()==44u+count*2u;check.close();}
   if(ok)ok=LittleFS.rename("/recording.tmp","/last.wav");
   lock();recordValidated=ok;recordFinished=true;recordFileOpen=false;if(!ok&&!audio.bad)audio.fail("WAV封口或字节长度校验失败");unlock();
   saveText("/record.json",recordingJson());
  }
 }
 bool persist=false;lock();persist=persistMap;persistMap=false;unlock();
 if(persist){String s=v041::mappingJson(activeMap,!activeMapEnabled);if(!saveText("/mapping.json",s)){lock();job.ok=false;job.error=11;job.message="FPGA映射已生效，但Flash保存失败";unlock();}}
}
inline String usbDispatch(const char* text,size_t length){
 v041::UsbCommand c;if(!v041::parseUsb(text,length,c))return "{\"usb_error\":\"invalid command\"}\n";
 if(c.kind==v041::UsbCommand::WAV_LINE){
  lock();bool valid=recordFinished&&recordValidated&&!recordFileOpen;unlock();
  if(!valid)return "{\"usb_wav\":{\"error\":\"no verified current WAV\"}}\n";
  File f=LittleFS.open("/last.wav","r");uint32_t samples=0;uint8_t data[512];size_t n=c.count;
  bool ok=f&&v046::wavSamples(f.size(),samples)&&v046::readWavRange(f,samples,c.offset,data,n);f.close();
  if(!ok)return "{\"usb_wav\":{\"error\":\"range/read\"}}\n";
  String result="{\"usb_wav\":{\"offset\":"+String(c.offset)+",\"data_hex\":\"";result.reserve(1150);const char* hex="0123456789abcdef";for(size_t i=0;i<n;++i){result+=hex[data[i]>>4];result+=hex[data[i]&15];}result+="\"}}\n";return result;
 }
 if(c.kind!=v041::UsbCommand::EXT_LINE)return "";
 lock();bool busy=job.running||bridge.inflight||rpc.inflight||bridge.queued;bool ready=bridge.ready();unlock();
 if(busy)return "{\"usb_ext\":{\"op\":"+String(c.op)+",\"status\":3,\"error\":\"busy\"}}\n";
 if(!ready)return "{\"usb_ext\":{\"op\":"+String(c.op)+",\"status\":6,\"error\":\"not_ready\"}}\n";
 if(c.op==48){const char* error="";bool zero=true;for(unsigned i=0;i<5;++i)zero=zero&&c.payload[i]==0;if(recording()||!zero||!prepareRecording(30,error))return "{\"usb_ext\":{\"op\":48,\"status\":6,\"error\":\"record/storage not ready\"}}\n";}
 lock();newJob(8,1);job.cap=true;job.rawOp=c.op;memcpy(job.rawData,c.payload,5);usbReply="";unlock();usbAwaiting=true;return "";
}
inline String usbPull(){lock();String r=usbReply;usbReply="";unlock();return r;}
inline void downloadWav(){
 lock();bool busy=recording();unlock();if(busy){jsonError(409,"录音尚未完成");return;}
 File f=LittleFS.open("/last.wav","r");uint32_t samples=0;
 if(!f||!v046::wavSamples(f.size(),samples)){f.close();jsonError(404,"没有校验通过的实际WAV");return;}
 // Same virtual byte view as USB, including requests crossing byte43/44.
 // Fixed Content-Length preserves playback/download semantics without a
 // second on-flash copy. A disconnected client cannot change the saved PCM.
 headers();server.sendHeader("Content-Disposition",server.hasArg("play")?"inline":"attachment; filename=Tang20K-recording.wav");
 size_t total=f.size();server.setContentLength(total);server.send(200,"audio/wav","");
 WiFiClient client=server.client();uint8_t data[1024];
 for(size_t offset=0;offset<total;){
  size_t n=total-offset;if(n>sizeof(data))n=sizeof(data);
  if(!v046::readWavRange(f,samples,offset,data,n)||client.write(data,n)!=n){client.stop();break;}
  offset+=n;delay(1);
 }
 f.close();
}
inline bool mountStorage(){
 if(LittleFS.begin(false,"/littlefs",4,"spiffs"))return true;
 // Initialize ONLY a completely erased factory partition. Existing/corrupt data
 // must use the explicit HTTP confirmation; never silently format user files.
 const esp_partition_t* p=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,ESP_PARTITION_SUBTYPE_DATA_SPIFFS,"spiffs");
 if(!p)return false;uint8_t bytes[256];
 for(size_t at=0;at<p->size;at+=sizeof(bytes)){size_t n=p->size-at;if(n>sizeof(bytes))n=sizeof(bytes);if(esp_partition_read(p,at,bytes,n)!=ESP_OK)return false;for(size_t i=0;i<n;++i)if(bytes[i]!=0xFF)return false;}
 return LittleFS.format()&&LittleFS.begin(false,"/littlefs",4,"spiffs");
}
inline void routes(){
 mutex=xSemaphoreCreateMutex();fsReady=mountStorage();
 if(fsReady&&LittleFS.exists("/mapping.json")){File f=LittleFS.open("/mapping.json","r");if(f.size()<=4096){bool p=false;const char* e="";bool dis=false;if(v041::mapJson(f.readString(),activeMap,p,e,&dis))activeMapEnabled=!dis;else{activeMap.defaults();activeMapEnabled=false;}}f.close();}
 server.on("/api/extensions/job",HTTP_GET,[](){lock();String s=jobJson();unlock();sendJson(s);});
 server.on("/api/extensions/config",HTTP_GET,[](){lock();String s="{\"score_active_confirmed\":"+String(activeScoreKnown?"true":"false")+",\"mapping_active_confirmed\":"+String(activeMapKnown?"true":"false")+",\"baud\":1000000,\"max_events\":63,\"max_beats_with_countin\":63,\"fs_hz\":15625}";unlock();sendJson(s);});
 server.on("/api/scores",HTTP_POST,[](){scoreSubmit(false);});
 server.on("/api/scores",HTTP_GET,[](){sendJson(String("{\"scores\":[")+(fsReady&&LittleFS.exists("/score.json")?"{\"id\":\"uploaded\",\"download\":\"/api/scores/download\"}":"")+"]}");});
 server.on("/api/scores/activate",HTTP_POST,[](){scoreSubmit(true);});
 server.on("/api/scores/control",HTTP_POST,[](){guideSubmit(6);});
 server.on("/api/guide/control",HTTP_POST,[](){guideSubmit(9);});
 server.on("/api/guide/mode",HTTP_POST,[](){guideSubmit(10);});
 server.on("/api/guide/state",HTTP_GET,[](){lock();String s=guideJson(millis());unlock();sendJson(s);});
 server.on("/api/guide/state",HTTP_POST,[](){guideSubmit(11);});
 server.on("/api/scores/download",HTTP_GET,[](){lock();bool busy=recording();unlock();if(busy){jsonError(409,"录音期间暂停文件下载");return;}File f=LittleFS.open("/score.json","r");if(!f){jsonError(404,"没有已上传曲谱");return;}headers();server.sendHeader("Content-Disposition","attachment; filename=score.json");server.streamFile(f,"application/json");f.close();});
 server.on("/api/mapping",HTTP_GET,[](){lock();String s=v041::mappingJson(activeMap,!activeMapEnabled);bool known=activeMapKnown;unlock();s.remove(s.length()-1);s+=String(",\"active_confirmed\":")+(known?"true":"false")+"}";sendJson(s);});
 server.on("/api/mapping",HTTP_PUT,[](){mappingSubmit(false);});
 server.on("/api/mapping/default",HTTP_POST,[](){mappingSubmit(true);});
 server.on("/api/recordings/start",HTTP_POST,startRecording);
 server.on("/api/recordings/stop",HTTP_POST,[](){lock();bool busy=recording();if(busy)stopRequested=true;unlock();if(!busy){jsonError(409,"没有录音");return;}sendJson("{\"accepted\":true,\"state\":\"draining\"}",202);});
 server.on("/api/recordings/current",HTTP_GET,[](){sendJson(recordingJson());});
 server.on("/api/recordings/last.wav",HTTP_GET,downloadWav);
 server.on("/api/storage/format",HTTP_POST,[](){if(!canConfigure()||!bodyLimit(128))return;if(server.arg("plain")!="{\"confirm\":\"FORMAT_LITTLEFS\"}"){jsonError(400,"需要明确确认初始化LittleFS");return;}LittleFS.end();fsReady=LittleFS.format()&&LittleFS.begin(false,"/littlefs",4,"spiffs");sendJson(fsReady?"{\"ok\":true}":"{\"ok\":false}",fsReady?200:507);});
 server.on("/api/extensions/tuning",HTTP_PUT,[](){if(!bodyLimit(128))return;const char* e="";cJSON* o=v041::parse(server.arg("plain"),128,e);int n=0;bool ok=o&&v041::integer(v041::item(o,"rx_frame_budget"),1,128,n);if(o)cJSON_Delete(o);if(!ok){jsonError(422,"rx_frame_budget须1..128");return;}lock();rxBudget=unsigned(n)*12;unlock();sendJson("{\"ok\":true}");});
 xTaskCreatePinnedToCore(uartTask,"v041-uart",6144,nullptr,3,nullptr,1);
}
} // namespace extension
