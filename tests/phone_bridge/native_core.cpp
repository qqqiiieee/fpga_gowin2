#include "../../esp32_phone/bridge_core.h"
#include <assert.h>
#include <stdio.h>
#include <vector>
#include <array>
#include <string>
#include <stdlib.h>
using namespace phone;
struct Rig {
  std::vector<std::array<uint8_t,12>> sent;
  Core c;
  uint8_t hw[16]={40,1,0,0,90,80,70,60,10,20,30,40,0,1,0,8};
  uint32_t now=0;
  static void tx(const uint8_t* b,size_t n,void* p) {
    assert(n==12); std::array<uint8_t,12> a; memcpy(a.data(),b,12);
    static_cast<Rig*>(p)->sent.push_back(a);
  }
  Rig():c(tx,this){}
  std::array<uint8_t,12> reply(uint8_t result=0,int effective=-1) {
    assert(c.inflight); uint8_t p=c.current.param;
    if(result==0 && c.current.cmd==1) hw[p]=effective<0?c.current.value:uint8_t(effective);
    std::array<uint8_t,12> b={0x5A,0xA5,1,c.frame[3],result,p,hw[p],hw[15],hw[1],hw[3],hw[0],0};
    b[11]=checksum(b.data());return b;
  }
  void inject(std::array<uint8_t,12> b) { for(auto v:b) c.receive(v,now); }
  void ack(uint8_t result=0,int effective=-1) {inject(reply(result,effective));}
  void tick(uint32_t delta=1) {now+=delta;c.tick(now);}
  void sync() {
    c.tick(now);
    for(unsigned guard=0;!c.ready()&&guard<40;++guard){assert(c.inflight);ack();tick();}
    assert(c.ready());
  }
  Values batch(uint8_t p,uint8_t v) {Values a;a.has[p]=true;a.value[p]=v;a.count=1;return a;}
  uint32_t set(uint8_t p,uint8_t v) {uint32_t r=0;assert(c.enqueue(batch(p,v),r));return r;}
  void finishRead(){if(c.inflight){assert(c.current.cmd==0);ack();}}
};
void codec(){
 uint8_t b[12];request(b,0xFE,1,0,123);
 const uint8_t gold[]={0xA5,0x5A,1,0xFE,1,0,123,0,0,0,0,0x85};assert(!memcmp(b,gold,12));
 request(b,0,0,15,0);assert(b[11]==0x0E);
 request(b,1,2,0,0);assert(b[11]==2);
 Rig r;r.c.tick(0);auto response=r.reply();
 Parser p;uint8_t out[12];assert(!p.feed(0x77,0,out));assert(!p.feed(0x5A,0,out));
 for(unsigned i=0;i<12;++i)assert(p.feed(response[i],1,out)==(i==11));assert(!memcmp(out,response.data(),12));
 auto bad=response;bad[11]^=1;for(auto v:bad)assert(!p.feed(v,2,out));
 for(unsigned i=0;i<12;++i)assert(p.feed(response[i],3,out)==(i==11));
 p.reset();p.feed(0x5A,10,out);p.feed(0xA5,11,out);assert(!p.feed(1,31,out));assert(p.used==0);
 for(unsigned i=0;i<12;++i)assert(p.feed(response[i],32,out)==(i==11));
 p.reset();p.feed(0x5A,UINT32_MAX-5,out);p.feed(0xA5,15,out);assert(p.used==0);
 // An embedded complete header in a malformed prefix must be preserved.
 p.reset();std::vector<uint8_t> noisy={0x5A,0xA5,1,0x55,0x22};noisy.insert(noisy.end(),response.begin(),response.end());
 unsigned received=0;for(auto v:noisy)if(p.feed(v,90,out))++received;assert(received==1);
 puts("PASS codec / XOR / resync / 20ms timeout / wrap");
}
void presets(){
 const char* good[]={"{\"volume\":255}"," { \"timbre\":1, \"input_mode\":0,\"hdmi_page\":3,\"filter\":1,\"digital_zero\":0 } \n",
 "{\"fx_mode\":3,\"fx_wet\":0,\"fx_time\":255,\"fx_feedback\":255,\"fx_modulation\":0,\"attack\":1,\"decay\":2,\"sustain\":3,\"release\":4}"};
 for(auto s:good){Values a;PresetParser p(s,strlen(s));assert(p.parse(a));assert(a.count>0);}
 const char* bad[]={"{}","[]","null","true","{\"volume\":256}","{\"timbre\":2}","{\"hdmi_page\":4}",
 "{\"volume\":-1}","{\"volume\":1.0}","{\"volume\":1e2}","{\"volume\":true}","{\"volume\":\"1\"}",
 "{\"volume\":01}","{\"volume\":1,}","{\"volume\":1}x","{\"volume\":1,\"volume\":2}",
 "{\"volume\":4,\"unknown\":0}","{\"volume\":4,\"status_flags\":1}","{\"volume\":4,\"filter\":2}",
 "{\"volume\":4,\"attack\":[]}","{\"__proto__\":0}","{\"vol\\u0075me\":2}"};
 for(auto s:bad){Values a;a.count=99;PresetParser p(s,strlen(s));assert(!p.parse(a));assert(a.count==99);}
 std::string huge(1025,' ');Values a;assert(!PresetParser(huge.c_str(),huge.size()).parse(a));
 puts("PASS strict JSON / ranges / duplicates / no partial mutation (26 vectors)");
}
void queueAndAck(){
 Rig r;uint32_t no=999;assert(!r.c.enqueue(r.batch(0,20),no));assert(no==999);r.sync();
 assert(r.c.values[0]==40&&r.c.values[1]==1);r.finishRead();
 auto rev=r.set(6,255);r.tick();assert(r.c.current.cmd==1&&r.c.current.param==6);
 auto transmissions=r.sent.size();r.tick(100);assert(r.sent.size()==transmissions);
 r.ack(0,200);assert(r.c.values[6]==200&&r.c.applied[6]!=rev&&r.c.failed[6]==rev&&r.c.errors[6]==12);
 // FTDI zero or test modes may keep actual mute/volume different from phone targets.
 rev=r.set(14,0);r.tick();r.ack(0,1);assert(r.c.values[14]==1&&r.c.failed[14]==rev&&r.c.errors[14]==12);
 rev=r.set(0,120);r.tick();r.ack(0,40);assert(r.c.values[0]==40&&r.c.failed[0]==rev&&r.c.errors[0]==12);
 rev=r.set(6,199);r.tick();r.ack();assert(r.c.applied[6]==rev&&r.c.values[6]==199);
 rev=r.set(2,1);r.tick();r.ack(2);assert(r.c.failed[2]==rev&&r.c.errors[2]==2&&r.c.applied[2]!=rev);
 for(uint8_t result=1;result<=4;++result){rev=r.set(1,0);r.tick();r.ack(result);assert(r.c.failed[1]==rev&&r.c.applied[1]!=rev);}
 for(unsigned i=0;i<1000;++i)r.set(4,uint8_t(i));assert(r.c.queued==1&&r.c.queue[0].value==231);
 // An invalid batch must not mutate an already populated queue or revision.
 Values invalid=r.batch(1,2);auto oldRevision=r.c.revision;assert(!r.c.enqueue(invalid,no));assert(r.c.revision==oldRevision&&r.c.queued==1);
 for(uint8_t p=0;p<15;++p)r.set(p,LIMITS[p]);assert(r.c.queued==15);
 r.tick(1000);assert(r.c.current.cmd==1); // write beats overdue volume/poll GET
 auto first=r.c.current;uint32_t panic;assert(r.c.panic(panic));assert(r.c.queued==1&&r.c.queue[0].cmd==2);
 assert(r.c.failed[5]==r.c.requested[5]&&r.c.errors[5]==11);
 r.ack();assert(r.c.applied[first.param]==first.revision);r.tick();assert(r.c.current.cmd==2);
 r.ack();assert(r.c.panicApplied==panic&&r.c.panicFailed!=panic);
 // Every ACK includes actual volume, including external physical slider ownership.
 r.hw[0]=211;r.tick(120);r.ack();assert(r.c.values[0]==211);
 r.c.seq=255;r.tick(120);assert(r.c.frame[3]==255);r.ack();r.tick(120);assert(r.c.frame[3]==0);r.ack();
 puts("PASS actual ACK / errors 1..4 / bounded coalesce / write priority / Panic / volume / seq wrap");
}
void reconnect(){
 Rig r;r.sync();r.finishRead();auto revision=r.set(4,44);r.tick();
 auto first=r.sent.back();auto queuedRev=r.set(5,55);r.tick(249);assert(r.c.attempts==1);
 r.tick(1);assert(r.c.attempts==2&&r.sent.back()==first);r.tick(250);assert(r.c.attempts==3&&r.sent.back()==first);
 r.tick(250);assert(!r.c.linked&&!r.c.synced&&!r.c.inflight&&r.c.queued==0);
 assert(r.c.failed[4]==revision&&r.c.failed[5]==queuedRev);for(bool v:r.c.valid)assert(!v);
 uint32_t nope;assert(!r.c.enqueue(r.batch(0,200),nope));
 auto n=r.sent.size();r.tick(999);assert(r.sent.size()==n);r.tick(1);assert(r.c.inflight&&r.c.current.cmd==0&&r.c.current.param==15);
 r.ack();assert(r.c.linked&&!r.c.synced);assert(!r.c.enqueue(r.batch(0,200),nope));
 for(unsigned i=0;!r.c.ready()&&i<40;++i){r.tick();assert(r.c.current.cmd==0);r.ack();}
 assert(r.c.ready()&&r.c.queued==0&&r.c.values[4]==r.hw[4]&&r.c.values[5]==r.hw[5]);
 // Every new connection starts with a readback; no pre-outage values are replayed.
 for(size_t i=n;i<r.sent.size();++i)assert(r.sent[i][4]==0);
 puts("PASS 250ms identical retries / outage clear / stale / automatic complete readback / no replay");
}
void corruptAndLate(){
 Rig r;r.sync();r.finishRead();auto rev=r.set(0,33);r.tick();auto good=r.reply();
 auto before=r.c.lastAck;auto rx=r.c.rxCount;
 auto bad=good;bad[3]++;bad[11]=checksum(bad.data());r.inject(bad);assert(r.c.inflight&&r.c.rxCount==rx);
 bad=good;bad[5]=1;bad[11]=checksum(bad.data());r.inject(bad);assert(r.c.inflight);
 bad=good;bad[7]=128;bad[11]=checksum(bad.data());r.inject(bad);assert(r.c.inflight);
 bad=good;bad[8]=2;bad[11]=checksum(bad.data());r.inject(bad);assert(r.c.inflight);
 bad=good;bad[4]=5;bad[11]=checksum(bad.data());r.inject(bad);assert(r.c.inflight);
 bad=good;bad[11]^=1;r.inject(bad);assert(r.c.inflight&&r.c.lastAck==before);
 r.inject(good);assert(!r.c.inflight&&r.c.applied[0]==rev);r.inject(good);assert(r.c.rxCount==rx+1);
 Rig wrap;wrap.now=UINT32_MAX-100;wrap.c.tick(wrap.now);auto f=wrap.sent.back();wrap.tick(250);assert(wrap.c.attempts==2&&wrap.sent.back()==f);
 puts("PASS corrupt / mismatched / duplicate ACK rejected / timer wrap");
}
int main(){_set_abort_behavior(0,_WRITE_ABORT_MSG|_CALL_REPORTFAULT);codec();presets();queueAndAck();reconnect();corruptAndLate();puts("ALL NATIVE BRIDGE TESTS PASSED (no hardware used)");}
