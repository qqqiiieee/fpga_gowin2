// Compile the REAL sketch serializer/routes against offline Arduino stubs.
#include "build/api_sketch.inc"
#include <assert.h>
#include <stdio.h>
#include <fstream>
int main(){
  setup();assert(bridge.telemetryEnabled&&fpgaUart.baud==115200&&fpgaUart.rx==16&&fpgaUart.tx==17);
  assert(Serial.baud==115200&&!Serial.debugOutput&&Serial.output.empty());
  bridge.linked=bridge.synced=true;
  for(unsigned i=0;i<phone::COUNT;++i){bridge.values[i]=0;bridge.valid[i]=true;}
  bridge.values[0]=40;bridge.values[2]=2;
  auto& t=bridge.telemetry;t.feature=phone::Telemetry::SUPPORTED;t.probed=t.valid=true;
  const uint8_t bytes[]={0x00,0x80,0xff,0x7f,255,63,0xff,0xb5,127,0,1,127,32,32,255};
  memcpy(t.bytes,bytes,15);t.capturedAt=100;t.snapshots=7;fakeMillis=130;
  stateRequest();assert(server.status==200);
  assert(server.response==makeState(fakeMillis));
  std::ofstream("build/api-state-fixture.json")<<server.response.c_str()<<"\n";
  // New read-only keys must be rejected by the actual HTTP apply route too.
  server.arguments["plain"]="{\"telemetry\":1}";applyParameters();assert(server.status==400&&bridge.queued==0);
  server.arguments["plain"]="{\"volume\":80}";applyParameters();assert(server.status==202&&bridge.queued==1);
  bridge.disconnect(fakeMillis);stateRequest();
  std::ofstream("build/api-disconnected-fixture.json")<<server.response.c_str()<<"\n";
  puts("PASS actual sketch state serializer / explicit telemetry enable / UART pins / strict HTTP apply / disconnect JSON");
}
