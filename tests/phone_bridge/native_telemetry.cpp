#include "../../esp32_phone/bridge_core.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <array>
#include <vector>
using namespace phone;
using Packet=std::array<uint8_t,12>;
using Snapshot=std::array<uint8_t,15>;
const Snapshot example={0x00,0x80,0xff,0x7f,255,63,0xff,0xb5,127,0,1,127,32,32,255};
struct Rig {
  std::vector<Packet> sent;
  Core c;
  uint32_t now=0;
  uint8_t hw[16]={40,1,2,0,90,80,70,60,10,20,30,40,0,1,0,8};
  static void tx(const uint8_t* b,size_t n,void* ctx) {
    assert(n==12); Packet p;memcpy(p.data(),b,12);static_cast<Rig*>(ctx)->sent.push_back(p);
  }
  Rig():c(tx,this,true){}
  void tick(uint32_t delta=1){now+=delta;c.tick(now);}
  Packet reply(uint8_t data,uint8_t result=0) {
    assert(c.inflight);
    Packet p={0x5a,0xa5,1,c.frame[3],result,c.current.param,data,hw[15],hw[1],hw[3],hw[0],0};
    p[11]=checksum(p.data());return p;
  }
  void inject(Packet p){for(auto b:p)c.receive(b,now);}
  void ack(uint8_t value,uint8_t result=0){inject(reply(value,result));}
  void normal(){assert(c.current.param<16);auto p=c.current.param;if(c.current.cmd==1)hw[p]=c.current.value;ack(hw[p]);}
  void sync(){
    for(unsigned i=0;!c.ready()&&i<64;++i){tick();assert(c.inflight&&c.current.param<16);normal();}
    assert(c.ready());
  }
  void probe(uint8_t result=0,uint8_t magic=0xa7){tick();assert(c.current.param==31);ack(magic,result);}
  void begin(){
    for(unsigned i=0;i<10;++i){tick();if(c.inflight&&c.current.param==16)return;if(c.inflight)normal();else now+=200;}
    assert(false);
  }
  void finish(const Snapshot& data=example){
    assert(c.inflight&&c.current.param==16);
    for(uint8_t p=16;p<=30;++p){assert(c.current.param==p);ack(data[p-16]);if(p<30)tick();}
    tick();assert(c.current.param==22&&c.telemetry.validating);ack(data[6]);
  }
  uint32_t set(uint8_t p,uint8_t v){Values b;b.has[p]=true;b.value[p]=v;b.count=1;uint32_t rev=0;assert(c.enqueue(b,rev));return rev;}
};
void assembly(){
 Rig r;r.sync();r.probe();assert(r.c.telemetry.feature==Telemetry::SUPPORTED);r.begin();
 auto start=r.now;for(uint8_t p=16;p<30;++p){r.ack(example[p-16]);assert(!r.c.telemetry.valid);r.tick();}
 r.ack(example[14]);auto& t=r.c.telemetry;
 assert(!t.valid&&t.snapshots==0&&t.validating);r.tick();assert(r.c.current.param==22);r.ack(example[6]);
 assert(t.valid&&t.snapshots==1&&t.capturedAt==start&&t.raw0()==0x8000&&t.raw1()==0x7fff);
 assert(t.bend()==-256&&t.bytes[4]==255&&t.bytes[6]==255&&t.bytes[12]==32);
 assert(!t.stale(start+999)&&t.stale(start+1000));
 for(int bend: {-256,-1,0,255}){
  r.now+=200;r.begin();Snapshot data=example;data[9]=uint8_t(bend);data[10]=uint8_t((bend&511)>>8);
  r.finish(data);assert(t.bend()==bend);
 }
 assert(r.c.ready());
 puts("PASS atomic 15-slot assembly plus end GET22 / LE RAW / signed9 BEND / capture-start age / 1s stale / 5Hz scheduling");
}
void corruptionAndDeadline(){
 Rig r;r.sync();r.probe();r.begin();r.finish();auto captured=r.c.telemetry.capturedAt;
 r.now+=200;r.begin();auto old=r.reply(0x11);r.ack(0x11);r.tick();r.ack(0x22);r.tick();
 auto good=r.reply(0x33),bad=good;bad[11]^=1;auto rx=r.c.rxCount,ack=r.c.lastAck;
 r.inject(bad);assert(r.c.inflight&&r.c.rxCount==rx&&r.c.lastAck==ack&&r.c.telemetry.capturedAt==captured);
 bad=good;bad[3]++;bad[11]=checksum(bad.data());r.inject(bad);assert(r.c.rxCount==rx);
 bad=good;bad[5]++;bad[11]=checksum(bad.data());r.inject(bad);assert(r.c.rxCount==rx);
 auto sent=r.sent.size();r.tick(250);assert(r.sent.size()==sent); // no capture/read retries
 r.now=r.c.telemetry.captureStart+500;r.c.tick(r.now);
 assert(!r.c.telemetry.active&&r.c.telemetry.aborted==1&&r.c.telemetry.capturedAt==captured);
 r.inject(good);r.inject(old);assert(r.c.telemetry.capturedAt==captured);
 if(r.c.inflight)r.normal();r.begin();assert(r.c.current.param==16);
 Snapshot next=example;next[0]=0xaa;next[1]=0xbb;r.finish(next);
 assert(r.c.telemetry.raw0()==0xbbaa&&r.c.telemetry.snapshots==2);
 puts("PASS bad XOR/mismatched/late replies never refresh / no GET16 retry / 500ms abort / restart GET16 / no mixed bytes");
}
void preemption(){
 Rig r;r.sync();r.probe();r.begin();r.ack(example[0]);
 auto rev=r.set(4,99);r.tick();assert(r.c.current.cmd==1&&r.c.current.param==4);r.normal();assert(r.c.applied[4]==rev);
 r.tick();assert(r.c.current.param==17);r.ack(example[1]);
 uint32_t panic;assert(r.c.panic(panic));r.tick();assert(r.c.current.cmd==2);r.normal();assert(r.c.panicApplied==panic);
 r.tick();assert(r.c.current.param==18);
 for(uint8_t p=18;p<=30;++p){r.ack(example[p-16]);if(p<30)r.tick();}
 // Controls retain priority even between slot30 and the final validation GET22.
 rev=r.set(6,42);r.tick();assert(r.c.current.cmd==1);r.normal();assert(r.c.applied[6]==rev);
 r.tick();assert(r.c.current.param==22&&r.c.telemetry.validating);r.ack(example[6]);
 assert(r.c.telemetry.valid);
 r.now+=200;r.begin();r.ack(7);rev=r.set(5,101);r.tick();assert(r.c.current.cmd==1);
 r.tick(500);assert(r.c.inflight&&r.c.current.cmd==1&&!r.c.telemetry.active); // preserve control request
 r.normal();assert(r.c.applied[5]==rev);r.begin();r.finish();assert(r.c.telemetry.raw0()==0x8000);
 puts("PASS SET/Panic preempt between packets / burst expiry preserves control inflight / clean capture restart");
}
void unsupportedAndRecovery(){
 Rig r;r.sync();r.probe(2);assert(r.c.telemetry.feature==Telemetry::UNSUPPORTED&&r.c.ready());
 size_t offset=r.sent.size();for(unsigned i=0;i<30;++i){r.tick(120);assert(r.c.current.param<16);r.normal();}
 for(size_t i=offset;i<r.sent.size();++i)assert(r.sent[i][5]<16);
 auto rev=r.set(0,80);r.tick();r.normal();assert(r.c.applied[0]==rev);
 r.c.disconnect(r.now);assert(!r.c.telemetry.valid&&!r.c.telemetry.probed);
 for(auto b:r.c.telemetry.bytes)assert(b==0);
 r.tick(1000);r.normal();r.sync();r.probe();r.begin();r.finish();assert(r.c.telemetry.valid);
 r.c.disconnect(r.now);assert(r.c.telemetry.bytes[6]==0&&r.c.telemetry.bytes[7]==0);
 Rig timeout;timeout.sync();timeout.tick();assert(timeout.c.current.param==31);timeout.tick(250);
 assert(timeout.c.ready()&&timeout.c.telemetry.feature==Telemetry::UNAVAILABLE&&!timeout.c.inflight);
 rev=timeout.set(4,55);timeout.tick();timeout.normal();assert(timeout.c.applied[4]==rev);
 puts("PASS old FPGA RESULT2 / controls retained / probe once per sync / disconnect clears flags / recovery / silent probe timeout");
}
void limitsAndWrap(){
 Rig r;r.sync();r.probe();r.begin();
 for(uint8_t p=16;p<=30;++p){
  if(p==24||p==26||p==27||p==28||p==29){
   uint8_t invalid=p==26?2:((p==28||p==29)?33:128);
   auto rx=r.c.rxCount;r.ack(invalid);assert(r.c.rxCount==rx&&r.c.inflight);
  }
  r.ack(example[p-16]);if(p<30)r.tick();
 }
 r.tick();assert(r.c.current.param==22);r.ack(example[6]);
 r.now+=200;r.begin();Snapshot invalid=example;invalid[6]&=127;r.finish(invalid);
 assert(!r.c.telemetry.valid&&r.c.telemetry.snapshots==1&&r.c.telemetry.bytes[6]==0);
 Values b;const char* bad[]={"{\"telemetry\":1}","{\"fsr0\":1}","{\"velocity\":1}","{\"status_flags\":1}"};
 for(auto text:bad)assert(!PresetParser(text,strlen(text)).parse(b));
 Rig wrap;wrap.now=UINT32_MAX-60;wrap.sync();wrap.probe();wrap.begin();wrap.finish();auto captured=wrap.c.telemetry.capturedAt;
 assert(!wrap.c.telemetry.stale(captured+999)&&wrap.c.telemetry.stale(captured+1000));
 puts("PASS telemetry field bounds / invalid snapshot flag / no preset writes / millis wrap");
}
void capabilityReprobe(){
 Rig r;r.sync();r.tick();assert(r.c.current.param==31);
 auto first=r.now,heartbeat=r.c.lastAck,rx=r.c.rxCount;
 assert(r.c.telemetry.lastCapabilityProbe==first);
 r.tick(250);assert(r.c.telemetry.feature==Telemetry::UNAVAILABLE&&r.c.ready());
 assert(r.c.lastAck==heartbeat&&r.c.rxCount==rx); // first capability ACK is lost
 while(uint32_t(r.now-first)<999){r.tick();if(r.c.inflight){assert(r.c.current.param<16);r.normal();}}
 unsigned probes=0;for(const auto& p:r.sent)if(p[5]==31)++probes;assert(probes==1);
 auto revision=r.set(4,61);r.tick();assert(r.c.current.cmd==1);r.normal();assert(r.c.applied[4]==revision);
 uint32_t panic;assert(r.c.panic(panic));r.tick();assert(r.c.current.cmd==2);r.normal();assert(r.c.panicApplied==panic);
 r.c.lastPoll=r.now-120;r.tick();assert(r.c.current.cmd==0&&r.c.current.param<16);r.normal();
 r.tick();assert(r.c.current.param==31&&uint32_t(r.now-first)>=1000);
 assert(r.c.telemetry.lastCapabilityProbe==r.now);r.ack(0xa7);
 r.begin();r.finish();assert(r.c.telemetry.valid&&r.c.telemetry.snapshots==1);

 // A continuously healthy parameter link must not hide corrupt capability ACKs
 // or cause a fast probe loop. Exercise the interval across millis() wrap too.
 Rig corrupt;corrupt.now=UINT32_MAX-350;corrupt.sync();
 auto origin=corrupt.now;size_t handled=corrupt.sent.size();std::vector<uint32_t> times;unsigned normal=0;
 while(uint32_t(corrupt.now-origin)<3500){
  corrupt.tick();
  if(corrupt.sent.size()==handled)continue;
  handled=corrupt.sent.size();
  if(corrupt.c.current.param==31){
   times.push_back(corrupt.now);auto packet=corrupt.reply(0xa7);packet[11]^=1;
   heartbeat=corrupt.c.lastAck;rx=corrupt.c.rxCount;corrupt.inject(packet);
   assert(corrupt.c.lastAck==heartbeat&&corrupt.c.rxCount==rx&&corrupt.c.inflight);
   assert(!corrupt.c.telemetry.valid&&corrupt.c.telemetry.snapshots==0);
  }else{assert(corrupt.c.current.param<16);corrupt.normal();++normal;}
 }
 assert(times.size()==4&&normal>=15&&corrupt.c.ready());
 for(size_t i=1;i<times.size();++i)assert(uint32_t(times[i]-times[i-1])>=1000);

 Rig wrong;wrong.sync();wrong.probe(0,0xa6);assert(wrong.c.telemetry.feature==Telemetry::UNSUPPORTED);
 for(unsigned i=0;i<30;++i){wrong.tick(120);assert(wrong.c.current.param<16);wrong.normal();}
 puts("PASS lost capability ACK -> 1s re-probe recovery / corrupt capability never refreshes heartbeat / no flood / SET+Panic+regular-poll priority / wrong magic stays unsupported / wrap");
}
void resetAfterFlags(){
 Rig r;r.sync();r.probe();r.begin();
 // A0/A1/levels/flags came from the old valid cache. FPGA resets after slot22;
 // subsequent reads ACK zero-filled cache bytes, including final GET22.
 for(uint8_t p=16;p<=30;++p){r.ack(p<=22?example[p-16]:0);if(p<30)r.tick();}
 auto& t=r.c.telemetry;assert(!t.valid&&t.snapshots==0&&t.validating);
 r.tick();assert(r.c.current.param==22);r.ack(0);
 assert(!t.valid&&!t.active&&!t.validating&&t.snapshots==0&&t.capturedAt==0&&t.aborted==1);
 for(auto b:t.bytes)assert(b==0);
 r.begin();assert(r.c.current.param==16);auto offset=r.sent.size()-1;r.finish();
 assert(t.valid&&t.snapshots==1&&t.raw0()==0x8000);
 assert(r.sent.size()-offset==16); // exactly GET16..30 plus ONE extra GET22
 for(unsigned i=0;i<15;++i)assert(r.sent[offset+i][5]==16+i);
 assert(r.sent.back()[5]==22);
 // A changed CAL/fault byte is also a failure, even with snapshotvalid still 1.
 auto captured=t.capturedAt;auto snapshots=t.snapshots;r.now+=200;r.begin();
 for(uint8_t p=16;p<=30;++p){r.ack(example[p-16]);if(p<30)r.tick();}
 assert(t.snapshots==snapshots&&t.capturedAt==captured);
 r.tick();assert(r.c.current.param==22);auto good=r.reply(example[6]);auto bad=good;bad[11]^=1;
 auto ack=r.c.lastAck,rx=r.c.rxCount;r.inject(bad);
 assert(r.c.inflight&&t.validating&&t.snapshots==snapshots&&t.capturedAt==captured&&r.c.lastAck==ack&&r.c.rxCount==rx);
 r.ack(example[6]^1);assert(!t.valid&&t.snapshots==snapshots&&t.capturedAt==captured&&t.aborted==2);
 r.begin();r.finish();assert(t.valid&&t.snapshots==snapshots+1);
 snapshots=t.snapshots;captured=t.capturedAt;r.now+=200;r.begin();
 for(uint8_t p=16;p<=30;++p){r.ack(example[p-16]);if(p<30)r.tick();}
 r.tick();r.ack(example[6],2);assert(!t.valid&&t.snapshots==snapshots&&t.capturedAt==captured);
 assert(t.feature==Telemetry::SUPPORTED);r.begin();r.finish();assert(t.valid&&t.snapshots==snapshots+1);
 puts("PASS FPGA reboot after slot22 / final GET22=0 rejects mixed cache / whole-byte mismatch / no valid/count/age refresh / recovery / exactly one end check");
}
int main(){_set_abort_behavior(0,_WRITE_ABORT_MSG|_CALL_REPORTFAULT);assembly();corruptionAndDeadline();preemption();unsupportedAndRecovery();limitsAndWrap();capabilityReprobe();resetAfterFlags();puts("ALL NATIVE TELEMETRY TESTS PASSED");}
