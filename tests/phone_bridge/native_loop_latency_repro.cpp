// READ-ONLY AUDIT REPRO SOURCE. Not compiled/executed in this audit: user forbids
// compilation. Includes the unchanged real Core for a future authorized run.
#include "../../esp32_phone/bridge_core.h"
#include <array>
#include <assert.h>
#include <stdio.h>
using Packet=std::array<uint8_t,12>;
struct LoopRig {
  phone::Core core;
  uint32_t now=1000;
  Packet buffered={};
  bool hasReply=false;
  static void send(const uint8_t* request,size_t length,void* ctx) {
    auto& r=*static_cast<LoopRig*>(ctx);assert(length==12&&!r.hasReply);
    uint8_t p=request[5];
    Packet b={0x5a,0xa5,1,request[3],0,p,0,0x38,0,0,40,0};
    if(p==0)b[6]=40;
    if(p==15)b[6]=0x38;
    if(p==22)b[6]=0x83;
    if(p==31)b[6]=0xa7;
    b[11]=phone::checksum(b.data());r.buffered=b;r.hasReply=true;
  }
  LoopRig():core(send,this,true) {
    // Steady healthy link; isolate loop scheduling from initial sync/feature probe.
    core.linked=core.synced=true;core.lastAck=now;
    for(auto& valid:core.valid)valid=true;
    core.telemetry.feature=phone::Telemetry::SUPPORTED;core.telemetry.probed=true;
    core.tick(now);
  }
  void step(uint32_t delay) {
    now+=delay;
    // UART response is complete ~2.1ms after request. For delay>=5ms all bytes
    // are in the ESP ring before the next loop, so no baud/link faults are used.
    if(hasReply){auto b=buffered;hasReply=false;for(auto v:b)core.receive(v,now);}
    core.tick(now);
  }
};
int main(){
  for(uint32_t gap: {5u,30u,32u,120u,150u}){
    LoopRig r;for(unsigned i=0;i<300;++i)r.step(gap);
    assert(r.core.ready());
    if(gap<=30)assert(r.core.telemetry.snapshots>0);
    if(gap==32)assert(r.core.telemetry.snapshots==0&&r.core.telemetry.aborted>0);
    if(gap>=120)assert(!r.core.telemetry.started&&r.core.telemetry.snapshots==0&&r.core.telemetry.aborted==0);
    printf("loop=%u ms ready=1 rx=%u snapshots=%u aborted=%u\n",gap,r.core.rxCount,r.core.telemetry.snapshots,r.core.telemetry.aborted);
  }
  LoopRig retry;retry.core.telemetry.feature=phone::Telemetry::UNAVAILABLE;
  for(unsigned i=0;i<100;++i)retry.step(120);
  assert(retry.core.ready()&&retry.core.telemetry.feature==phone::Telemetry::UNAVAILABLE);
  assert(retry.core.telemetry.lastCapabilityProbe==0); // same poll-age gate also starves re-probes
  LoopRig split;auto b=split.buffered;split.hasReply=false;
  // FPGA's entire physical response arrives by 1002.2ms, but main loop drains
  // its prefix at 1001ms and suffix at 1051ms after a blocking HTTP operation.
  for(unsigned i=0;i<6;++i)split.core.receive(b[i],1001);
  assert(split.core.parser.used==6);
  auto rx=split.core.rxCount;
  for(unsigned i=6;i<12;++i)split.core.receive(b[i],1051);
  assert(split.core.rxCount==rx&&split.core.inflight);
  puts("Buffered valid ACK discarded solely because parser measures drain-time gap, not UART wire gap");
}
