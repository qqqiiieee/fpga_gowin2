// Test actual runtime functions extracted by run_tests.py, with deterministic
// time, UART and bridge. The protocol codec/RPC/audio implementation is real.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <array>
#include <string>
#include <type_traits>
#include <cmath>
#include "../../esp32_phone/v041_core.h"
struct String : std::string {
 using std::string::string;
 String()=default;String(const std::string& s):std::string(s){}
 template<class T,typename std::enable_if<std::is_integral<T>::value,int>::type=0>
 String(T n):std::string(std::to_string(n)){}
};
static uint32_t testClock=1000;uint32_t millis(){return testClock;}
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x)){printf("FAIL line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
struct FakeBridge {
 bool inflight=false,queued=false,linked=true,synced=true;uint8_t seq=0;
 uint32_t lastAck=1000,panicFailed=0,panicApplied=0;unsigned ticks=0,aborts=0;
 struct{bool active=false;}telemetry;
 bool ready(){return linked&&synced;}
 void tick(uint32_t t){++ticks;lastAck=t;}
 void abortTelemetry(){++aborts;telemetry.active=false;}
 bool panic(uint32_t& r){r=++panicApplied;return true;}
} bridge;
std::vector<std::array<uint8_t,12>> packets;
void uartSend(const uint8_t* p,size_t,void*){std::array<uint8_t,12>a;for(int i=0;i<12;++i)a[i]=p[i];packets.push_back(a);}
v041::Score score;v041::Mapping map,activeMap;v041::Rpc rpc;
bool sink(const uint8_t*,size_t,void*){return true;}v041::Audio audio(sink,nullptr);
bool activeScoreKnown=false,activeMapKnown=false,activeMapEnabled=false,persistMap=false,recordFileOpen=false,recordValidated=false,recordFinished=false,stopRequested=false,crcKnown=false,remoteBusy=false;
uint32_t nextJob=0,recordStarted=0,lastAudioAt=1000,remoteStopAt=0,fpgaCrc=0;unsigned recordSeconds=30,stopAttempts=0;
bool recording(){return recordFileOpen&&!recordFinished;}
void usbResult(uint8_t,uint8_t,uint32_t){}
#include "runtime_under_test.inc"
// AST fixtures isolate the new HTTP handler from the unchanged cJSON parser.
// integer/item/keys, body validation and guideSubmit are extracted verbatim.
using std::isfinite;
struct cJSON {cJSON* child=nullptr; cJSON* next=nullptr;const char* string="";int type=1;double valuedouble=0;};
bool cJSON_IsNumber(const cJSON* p){return p&&p->type==1;}
cJSON* cJSON_GetObjectItemCaseSensitive(cJSON* p,const char* name){for(auto a=p->child;a;a=a->next)if(!strcmp(a->string,name))return a;return nullptr;}
void cJSON_Delete(cJSON*){}
cJSON root;std::vector<cJSON> fields;bool invalidJson=false;
namespace v041 {cJSON* parse(const String&,size_t,const char*&){return invalidJson?nullptr:&root;}}
#include "json_helpers_under_test.inc"
int httpCode=0,lockDepth=0;String httpBody;
struct FakeServer {
 String body="{}",contentType="application/json";bool hasBody=true;
 String header(const char*){return contentType;}bool hasArg(const char*){return hasBody;}String arg(const char*){return body;}
 void send(int code,const char*,const String& s){CHECK(lockDepth==0);httpCode=code;httpBody=s;}
}server;
void headers(){}void lock(){++lockDepth;}void unlock(){--lockDepth;}
void jsonError(int code,const char* message){CHECK(lockDepth==0);httpCode=code;httpBody=message;}
#include "http_under_test.inc"
void body(std::initializer_list<std::pair<const char*,double>> items){
 root=cJSON();fields.clear();for(auto p:items){cJSON n;n.string=p.first;n.valuedouble=p.second;fields.push_back(n);}
 for(size_t i=1;i<fields.size();++i)fields[i-1].next=&fields[i];root.child=fields.empty()?nullptr:&fields[0];invalidJson=false;server=FakeServer();httpCode=0;
}
void reset(){
 testClock=1000;bridge=FakeBridge();rpc=v041::Rpc();job=Job();guide=GuideCache();guideRefreshAt=0;guideRefreshStarted=false;
 packets.clear();audio=v041::Audio(sink,nullptr);recordFileOpen=recordFinished=recordValidated=stopRequested=remoteBusy=crcKnown=false;recordStarted=remoteStopAt=stopAttempts=0;lastAudioAt=testClock;nextJob=0;
}
void ack(uint32_t reply=0,uint8_t status=0){
 uint8_t b[12]={0x5A,0xA5,1,rpc.frame[3],uint8_t(status?0x21:0x20),rpc.frame[5],status};v041::put32(b+7,reply);b[11]=phone::checksum(b);CHECK(rpc.receive(b));
}
void tick(){bridge.lastAck=testClock;scheduler(testClock);++testClock;}
void begin(uint8_t kind,uint8_t song,uint8_t action){
 CHECK(enqueueGuide(kind,song,action,testClock)==202);tick();CHECK(rpc.inflight&&rpc.frame[5]==0);ack(0x10007);tick();
}
bool has(const String& s,const char* text){return s.find(text)!=std::string::npos;}
void readback(uint32_t raw){CHECK(rpc.frame[5]==22);CHECK(v041::le32(rpc.frame+6)==0&&rpc.frame[10]==0);ack(raw);tick();}
int main(){
 reset();CHECK(has(guideJson(testClock),"\"mode\":null")&&has(guideJson(testClock),"\"verified\":false"));
 // Every mode and every status bit, including separate selected/rolling songs.
 for(unsigned mode=0;mode<3;++mode)for(unsigned song=0;song<4;++song){
  for(unsigned bit=2;bit<24;++bit){uint32_t raw=(1u<<bit)|mode;CHECK(guide.accept(raw,testClock));CHECK(guide.raw==raw&&guide.mode()==mode);String one=guideJson(testClock);
   CHECK(has(one,(String("\"roll_song\":")+String((raw>>2)&3)).c_str()));CHECK(has(one,(String("\"selected_song\":")+String((raw>>22)&3)).c_str()));
   CHECK(has(one,bit==4?"\"active\":true":"\"active\":false"));CHECK(has(one,bit==5?"\"done\":true":"\"done\":false"));CHECK(has(one,bit==6?"\"practice_hold\":true":"\"practice_hold\":false"));CHECK(has(one,bit==7?"\"external_suspend\":true":"\"external_suspend\":false"));
   CHECK(has(one,(String("\"step\":")+String((raw>>8)&63)).c_str()));CHECK(has(one,(String("\"expected_note\":")+String((raw>>14)&127)).c_str()));CHECK(has(one,bit==21?"\"expected_valid\":true":"\"expected_valid\":false"));
  }
  uint32_t raw=mode|(song<<2)|(15u<<4)|(63u<<8)|(127u<<14)|(1u<<21)|(((song+1)%4)<<22);
  CHECK(guide.accept(raw,testClock));String s=guideJson(testClock);CHECK(has(s,(String("\"mode\":")+String(mode)).c_str()));
  CHECK(has(s,(String("\"roll_song\":")+String(song)).c_str()));CHECK(has(s,(String("\"selected_song\":")+String((song+1)%4)).c_str()));
  for(const char* text:{"\"active\":true","\"done\":true","\"practice_hold\":true","\"external_suspend\":true","\"step\":63","\"expected_note\":127","\"expected_valid\":true"})CHECK(has(s,text));
 }
 CHECK(guide.accept(0,testClock));CHECK(has(guideJson(testClock),"\"expected_valid\":false"));
 CHECK(guide.fresh(testClock+3000,true)&&!guide.fresh(testClock+3001,true));CHECK(guide.verified);
 CHECK(!guide.fresh(testClock,false));CHECK(guide.accept(1,0xfffffff0u));CHECK(guide.fresh(0x20u,true)&&!guide.fresh(0x2000u,true));
 for(uint32_t raw:{3u,0x01000000u,0x80000000u,0xff000000u}){CHECK(!guide.accept(raw,testClock)&&!guide.verified);CHECK(guide.raw==1);}
 // SET ACK contains the requested value, but only op22 supplies the state.
 for(unsigned mode=0;mode<3;++mode){reset();begin(10,3,uint8_t(mode));CHECK(rpc.frame[5]==21&&rpc.frame[6]==mode);CHECK(v041::le32(rpc.frame+7)==0);ack(mode);tick();CHECK(job.running&&!job.ok&&job.requestAccepted&&!job.stateVerified&&!guide.verified);readback(mode|(2u<<22));CHECK(job.ok&&job.stateVerified&&job.targetMatch&&job.progress==2&&guide.mode()==mode);}
 for(unsigned song=0;song<4;++song)for(unsigned action=0;action<4;++action){
  reset();begin(9,uint8_t(song),uint8_t(action));CHECK(rpc.frame[5]==20&&v041::le32(rpc.frame+6)==((1u<<16)|(song<<8)|action)&&rpc.frame[10]==0);
  ack((1u<<16)|(song<<8)|action);tick();CHECK(job.running&&!guide.have);readback((song<<22)|(song<<2)|(action?16:0));CHECK(job.ok&&guide.selectedSong()==song);
 }
 for(unsigned action=0;action<4;++action){reset();begin(6,3,uint8_t(action));CHECK(rpc.frame[5]==20&&v041::le32(rpc.frame+6)==action&&rpc.frame[10]==0);ack(action);tick();readback(3u<<22);CHECK(job.ok);}
 // Mismatches fail the job but preserve the verified *actual* readback.
 reset();begin(10,3,2);ack(2);tick();readback(1);CHECK(!job.ok&&job.error==12&&job.stateVerified&&guide.verified&&guide.mode()==1);
 reset();begin(9,2,1);ack(0x10201);tick();readback(1u<<22);CHECK(!job.ok&&job.error==12&&guide.selectedSong()==1);
 reset();begin(10,3,1);ack(1);tick();readback(3);CHECK(!job.ok&&job.error==13&&!guide.verified);
 reset();begin(11,3,0);CHECK(!job.requestAccepted);readback(2|(1u<<7));CHECK(job.ok&&job.stateVerified&&job.progress==1);
 CHECK(enqueueGuide(11,3,0,testClock)==429);testClock+=1000;CHECK(enqueueGuide(11,3,0,testClock)==202);
 // NACKs, unsupported old FPGA, and lost op22 never substitute request values.
 reset();CHECK(guide.accept(2,testClock));begin(10,3,1);ack(0,2);tick();CHECK(!job.ok&&!job.requestAccepted&&!guide.verified&&guide.raw==2);
 reset();CHECK(enqueueGuide(10,3,1,testClock)==202);tick();ack(0x10008);tick();CHECK(!job.ok&&packets.size()==1&&!guide.verified);
 reset();begin(10,3,1);ack(1);tick();ack(0,2);tick();CHECK(!job.ok&&job.requestAccepted&&!job.stateVerified&&!guide.verified);
 reset();begin(10,3,1);auto set=packets.back();testClock+=500;tick();CHECK(packets.back()==set);ack(1);tick();auto read=packets.back();
 for(int i=0;i<2;++i){testClock+=500;tick();CHECK(packets.back()==read);}testClock+=500;tick();tick();CHECK(!job.running&&!job.ok&&job.error==10&&job.requestAccepted&&!guide.verified);
 // Wrong sequence/op/checksum cannot verify a state.
 reset();begin(11,3,0);uint8_t b[12]={0x5a,0xa5,1,uint8_t(rpc.frame[3]+1),0x20,22,0};b[11]=phone::checksum(b);CHECK(!rpc.receive(b));b[3]=rpc.frame[3];b[5]=21;b[11]=phone::checksum(b);CHECK(!rpc.receive(b));b[5]=22;b[11]=phone::checksum(b)^1;CHECK(!rpc.receive(b)&&!guide.verified);readback(0);CHECK(job.ok);
 // Existing recording/queue/bridge transactions take precedence. GET is pure.
 for(int busy=0;busy<8;++busy){reset();switch(busy){case 0:recordFileOpen=true;break;case 1:remoteBusy=true;break;case 2:audio.active=true;lastAudioAt=testClock;break;case 3:stopRequested=true;break;case 4:job.running=true;break;case 5:rpc.inflight=true;break;case 6:bridge.queued=true;break;case 7:recordFileOpen=true;audio.eof=true;break;}
  CHECK(enqueueGuide(9,0,1,testClock)==409);CHECK(enqueueGuide(10,3,1,testClock)==409);CHECK(enqueueGuide(11,3,0,testClock)==409);for(int i=0;i<100;++i)guideJson(testClock);CHECK(packets.empty());}
 reset();bridge.linked=false;CHECK(enqueueGuide(11,3,0,testClock)==503);CHECK(guide.accept(1,testClock));tick();CHECK(!guide.verified);bridge.linked=true;CHECK(!guide.fresh(testClock,true));
 reset();bridge.synced=false;CHECK(enqueueGuide(10,3,0,testClock)==503);
 reset();CHECK(enqueueGuide(10,3,1,testClock)==202);bridge.inflight=true;tick();CHECK(packets.empty());bridge.inflight=false;bridge.queued=true;tick();CHECK(packets.empty());bridge.queued=false;bridge.telemetry.active=true;tick();CHECK(packets.size()==1&&bridge.aborts==1);auto n=packets.size();tick();CHECK(packets.size()==n);
 reset();for(int i=0;i<10000;++i)tick();CHECK(packets.empty()); // no autonomous UART polling
 // The unchanged stop/drain/CRC branch still owns the existing job queue.
 reset();recordFileOpen=remoteBusy=audio.active=stopRequested=true;tick();CHECK(job.kind==4&&rpc.frame[5]==49&&stopAttempts==1);ack();tick();CHECK(job.running&&job.step==1);audio.eof=true;audio.active=remoteBusy=false;tick();tick();CHECK(job.kind==5&&rpc.frame[5]==50);ack(audio.finalCrc());tick();CHECK(recordValidated&&job.ok);
 // Actual HTTP handler: strict integer fields, bounds, unknown/missing keys,
 // body limits, queue/recording exclusion and no UART work inside HTTP.
 for(int mode=0;mode<3;++mode){reset();body({{"mode",double(mode)}});guideSubmit(10);CHECK(httpCode==202&&job.action==mode&&job.kind==10&&packets.empty());CHECK(has(httpBody,"\"request_accepted\":false")&&has(httpBody,"\"state_verified\":false"));}
 for(int song=0;song<4;++song)for(int action=0;action<4;++action){reset();body({{"song",double(song)},{"action",double(action)}});guideSubmit(9);CHECK(httpCode==202&&job.song==song&&job.action==action);}
 for(double mode:{-1.0,3.0,1.5,double(INFINITY),double(NAN)}){reset();body({{"mode",mode}});guideSubmit(10);CHECK(httpCode==422&&!job.running);}
 for(int bad=0;bad<8;++bad){reset();body({{"song",0},{"action",1}});switch(bad){case 0:root.child=nullptr;break;case 1:fields[0].next=nullptr;break;case 2:fields[0].valuedouble=4;break;case 3:fields[1].valuedouble=-1;break;case 4:fields[0].string="unknown";break;case 5:fields[0].type=2;break;case 6:fields[1].valuedouble=0.5;break;case 7:invalidJson=true;break;}guideSubmit(9);CHECK(httpCode==422&&!job.running);}
 reset();body({{"action",2}});guideSubmit(6);CHECK(httpCode==202&&job.kind==6&&job.song==3);
 reset();body({});guideSubmit(11);CHECK(httpCode==202&&job.kind==11);job.running=false;guideSubmit(11);CHECK(httpCode==429);
 reset();body({{"mode",0}});guideSubmit(11);CHECK(httpCode==422);
 for(int bad=0;bad<3;++bad){reset();body({{"mode",1}});if(bad==0)server.contentType="text/plain";if(bad==1)server.hasBody=false;if(bad==2)server.body=std::string(129,' ');guideSubmit(10);CHECK(httpCode==413&&!job.running);}
 reset();body({{"mode",1}});recordFileOpen=true;guideSubmit(10);CHECK(httpCode==409&&!job.running);recordFileOpen=false;bridge.linked=false;guideSubmit(10);CHECK(httpCode==503&&!job.running);CHECK(lockDepth==0);
 printf("V045_GUIDE_NATIVE_PASS checks=%u modes=3 songs=4 actions=4 status_bits=24 ack_vs_readback=1 mismatch=1 stale=1 errors=1 recording_mutex=1\n",checks);
 return 0;
}
