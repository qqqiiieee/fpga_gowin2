// Offline test of the actual V039 sketch, no serial devices/network involved.
#include "build/api_sketch.inc"
#include <assert.h>
#include <stdio.h>
#include <fstream>
#include <algorithm>
#include <string>

void clearUsb(){
  Serial.input.clear();Serial.output.clear();Serial.txSpace=128;Serial.wouldBlockWrites=0;
  usbCommandLength=0;usbDiscardLine=false;usbStateReply=String();usbStateOffset=0;
}
void drainUsb(int capacity=17){
  for(unsigned n=0;n<10000&&(Serial.available()||usbStateReply.length());++n){Serial.txSpace=capacity;serviceUsbDiagnostic();}
  assert(!Serial.available()&&!usbStateReply.length()&&Serial.wouldBlockWrites==0);
}
std::string output(){return std::string(Serial.output.begin(),Serial.output.end());}
void commands(){
  clearUsb();const auto beforeFpga=fpgaUart.output.size();const auto tx=bridge.txCount,rev=bridge.revision;
  Serial.inject("STA");serviceUsbDiagnostic();assert(Serial.output.empty());
  Serial.inject("TE");serviceUsbDiagnostic();assert(Serial.output.empty());
  Serial.inject("\n");drainUsb(7);
  stateRequest();assert(output()==std::string(server.response.c_str())+"\n");
  assert(std::count(Serial.output.begin(),Serial.output.end(),'\n')==1);
  assert(fpgaUart.output.size()==beforeFpga&&bridge.txCount==tx&&bridge.revision==rev&&bridge.queued==0);
  assert(rawUartRxBytes==0);
  const std::string invalid[]={"\n","state\n","STATE \n"," STATE\n","STATE\r\n",
    "SET volume 255\n","PANIC\n","{\"volume\":0}\n",std::string("STATE\0\n",7),std::string(200,'x')+"STATE\n"};
  for(const auto& command:invalid){clearUsb();Serial.inject(command);drainUsb();assert(Serial.output.empty());}
  assert(bridge.revision==rev&&bridge.queued==0&&fpgaUart.output.size()==beforeFpga);
  clearUsb();Serial.inject(std::string(200,'x'));serviceUsbDiagnostic();
  assert(Serial.available()==136&&Serial.output.empty()&&usbDiscardLine); // 64-byte RX work bound
  Serial.inject("\nSTATE\n");drainUsb();assert(output()==std::string(makeState(fakeMillis).c_str())+"\n");
  clearUsb();Serial.inject("STATE\nSTATE\n");drainUsb(1);
  const auto expected=std::string(makeState(fakeMillis).c_str())+"\n";assert(output()==expected+expected);
  clearUsb();for(unsigned i=0;i<100;++i)serviceUsbDiagnostic();assert(Serial.output.empty());
  puts("PASS exact STATE/LF only / fragmented command / single-line full HTTP-equivalent JSON / no SET/Panic / length+RX bounds / line recovery / no periodic logs / UART separation");
}
void backpressure(){
  clearUsb();fakeMillis=100;const auto expected=std::string(makeState(fakeMillis).c_str())+"\n";
  Serial.txSpace=0;Serial.inject("STATE\n");serviceUsbDiagnostic();
  assert(Serial.output.empty()&&usbStateReply.length()>0);
  for(unsigned i=0;i<10;++i)serviceUsbDiagnostic();assert(Serial.output.empty()&&Serial.wouldBlockWrites==0);
  fakeMillis=900;Serial.txSpace=128;serviceUsbDiagnostic();assert(Serial.output.size()==64); // TX work bound
  drainUsb(3);assert(output()==expected); // state captured at command, never split across live snapshots
  clearUsb();puts("PASS TX-space backpressure / max64-byte TX chunks / nonblocking drain / one frozen JSON per command");
}
void rawCounter(){
  bridge=phone::Core(uartSend,nullptr,true);fakeMillis=1;rawUartRxBytes=0;
  fpgaUart.input.clear();fpgaUart.output.clear();fpgaUart.txSpace=4096;clearUsb();
  fpgaUart.inject(std::string("\x99\x00\xff",3));loop();assert(rawUartRxBytes==3&&bridge.rxCount==0);
  loop();assert(rawUartRxBytes==3&&bridge.rxCount==0);
  uint8_t ack[]={0x5a,0xa5,1,bridge.frame[3],0,bridge.current.param,8,8,0,0,40,0};
  ack[11]=phone::checksum(ack);for(auto b:ack)fpgaUart.input.push_back(b);
  loop();assert(rawUartRxBytes==15&&bridge.rxCount==1);
  ack[3]=bridge.frame[3];ack[5]=bridge.current.param;ack[6]=0;ack[11]=phone::checksum(ack)^1;
  for(auto b:ack)fpgaUart.input.push_back(b);loop();assert(rawUartRxBytes==27&&bridge.rxCount==1);
  fpgaUart.inject("w");fpgaUart.failNextRead=true;loop();assert(rawUartRxBytes==27&&fpgaUart.available()==1);
  loop();assert(rawUartRxBytes==28&&bridge.rxCount==1&&Serial.output.empty());
  Serial.inject("STATE\n");drainUsb();stateRequest();
  assert(rawUartRxBytes==28&&output()==std::string(server.response.c_str())+"\n");
  std::ofstream("build/v039-usb-state.json")<<output();
  std::ofstream("build/v039-http-state.json")<<server.response.c_str()<<"\n";
  puts("PASS raw UART2 counts real bytes incl noise/bad XOR / read(-1) excluded / rx remains accepted frames / USB does not affect UART2 counters");
}
int main(){
 setup();assert(Serial.baud==115200&&Serial.txBufferSize==256&&!Serial.debugOutput&&Serial.output.empty());
 assert(fpgaUart.baud==115200&&fpgaUart.rx==16&&fpgaUart.tx==17);
 commands();backpressure();rawCounter();puts("ALL V039 NATIVE USB TESTS PASSED (no hardware used)");
}
