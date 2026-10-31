#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include "bridge_core.h"
#include "web_ui.h"
#include "v041_ui.h"
#include "recording_uart.h"
void bridgeLock();
void bridgeUnlock();
String usbDispatchLine(const char*,size_t);
String usbPullAsync();

// Change these two strings to rename/protect your own AP (password >=8 bytes).
static const char AP_SSID[] = "Tang20K-Music";
static const char AP_PASSWORD[] = "fpga2026";
static const int FPGA_RX = 16; // ESP RX2 <- FPGA PMOD3 N8 TX
static const int FPGA_TX = 17; // ESP TX2 -> FPGA PMOD3 L9 RX
static DRAM_ATTR RecordingUart fpgaUart;
WebServer server(80);
void uartSend(const uint8_t* bytes,size_t length,void*) { fpgaUart.write(bytes,length); }
phone::Core bridge(uartSend,nullptr,true); // additive read-only capability probe
uint32_t bootId=0;
static const char FIRMWARE_VERSION[] = "V047";
// Bytes actually returned by UART2.read(), including malformed/noisy data.
// bridge.rxCount still counts only fully accepted ACK frames.
uint32_t rawUartRxBytes=0;
static char usbCommand[64];
static uint8_t usbCommandLength=0;
static bool usbDiscardLine=false;
static bool usbAwaiting=false;
static String usbStateReply;
static size_t usbStateOffset=0;

void headers() {
  server.sendHeader("Cache-Control", "no-store");
  server.sendHeader("X-Content-Type-Options", "nosniff");
  server.sendHeader("X-Frame-Options", "DENY");
}
void jsonError(int code,const char* text) {
  headers(); server.send(code,"application/json; charset=utf-8",String("{\"error\":\"")+text+"\"}");
}
bool jsonBody() {
  if(server.header("Content-Type")!="application/json") {
    jsonError(415,"需要 application/json"); return false;
  }
  if(!server.hasArg("plain") || server.arg("plain").length()>1024) {
    jsonError(413,"JSON 不能为空且最多 1024 字节"); return false;
  }
  return true;
}
void accepted(uint32_t rev) {
  headers(); server.send(202,"application/json; charset=utf-8",
    String("{\"accepted\":true,\"revision\":")+String(rev)+"}");
}
void applyParameters() {
  if(!jsonBody()) return;
  String body=server.arg("plain"); phone::Values batch;
  phone::PresetParser parser(body.c_str(),body.length());
  if(!parser.parse(batch)) {
    jsonError(400,"整份预设已拒绝：仅允许已知可写键和范围内十进制整数，禁止重复字段"); return;
  }
  uint32_t rev=0; bridgeLock();
  bool ready=bridge.ready(); bool queued=ready && bridge.enqueue(batch,rev); bridgeUnlock();
  if(!ready){jsonError(503,"FPGA 状态过期或正在恢复回读，未接受写入");return;}
  if(!queued){jsonError(429,"队列已满，未接受任何参数");return;}
  accepted(rev); // accepted is not an FPGA acknowledgement.
}
void panicRequest() {
  if(!jsonBody()) return;
  if(server.arg("plain")!="{}") {jsonError(400,"Panic 只接受空对象 {}");return;}
  uint32_t rev;
  bridgeLock();bool queued=bridge.panic(rev);bridgeUnlock();
  if(!queued) {jsonError(503,"FPGA 断链或正在回读，Panic 未发送");return;}
  accepted(rev);
}
String telemetryJson(uint32_t now) {
  const phone::Telemetry& t=bridge.telemetry;
  const uint8_t flags=t.bytes[6], beams=t.bytes[7], test=t.bytes[14];
  const char* status=!bridge.telemetryEnabled ? "disabled" :
    (t.feature==phone::Telemetry::SUPPORTED ? "supported" :
    (t.feature==phone::Telemetry::UNSUPPORTED ? "unsupported" :
    (t.feature==phone::Telemetry::UNAVAILABLE ? "unavailable" : "probing")));
  String out; out.reserve(1100);
  out="{\"enabled\":"; out+=bridge.telemetryEnabled?"true":"false";
  out+=",\"status\":\""; out+=status; out+="\",\"supported\":";
  out+=t.feature==phone::Telemetry::SUPPORTED?"true":"false";
  out+=",\"valid\":"; out+=t.valid?"true":"false";
  out+=",\"stale\":"; out+=t.stale(now)?"true":"false";
  out+=",\"age_ms\":"; out+=t.valid?String(t.age(now)):String("null");
  out+=",\"snapshot_id\":"; out+=String(t.snapshots);
  out+=",\"snapshot_valid\":"; out+=(flags&128)?"true":"false";
  out+=",\"aborted_bursts\":"; out+=String(t.aborted);
  out+=",\"fsr\":[";
  for(unsigned i=0;i<2;++i) {
    if(i) out+=',';
    out+="{\"raw\":"; out+=String(i?t.raw1():t.raw0());
    out+=",\"level\":"; out+=String(t.bytes[4+i]);
    out+=",\"calibrated\":"; out+=(flags&(1<<i))?"true":"false"; out+='}';
  }
  out+="],\"adc\":{\"fault\":"; out+=(flags&4)?"true":"false";
  out+=",\"stale\":"; out+=(flags&8)?"true":"false";
  out+="},\"midi\":{\"velocity\":"; out+=String(t.bytes[8]);
  out+=",\"bend\":"; out+=String(t.bend());
  out+=",\"modulation\":"; out+=String(t.bytes[11]);
  out+=",\"frame_error\":"; out+=(flags&32)?"true":"false";
  out+=",\"overflow\":"; out+=(flags&64)?"true":"false";
  out+="},\"beams\":{\"electrical_a\":"; out+=(beams&1)?"true":"false";
  out+=",\"electrical_b\":"; out+=(beams&2)?"true":"false";
  out+=",\"blocked_a\":"; out+=(beams&4)?"true":"false";
  out+=",\"blocked_b\":"; out+=(beams&8)?"true":"false";
  out+=",\"enabled\":"; out+=(beams&16)?"true":"false";
  out+=",\"ready\":"; out+=(flags&16)?"true":"false";
  out+=",\"busy\":"; out+=(beams&32)?"true":"false";
  out+="},\"voices\":"; out+=String(t.bytes[12]);
  out+=",\"test\":{\"mode\":"; out+=(beams&64)?"true":"false";
  out+=",\"owned\":"; out+=(beams&128)?"true":"false";
  out+=",\"requested\":"; out+=String(t.bytes[13]);
  out+=",\"active\":"; out+=(test&1)?"true":"false";
  out+=",\"sweep\":"; out+=(test&2)?"true":"false";
  out+=",\"overrun\":"; out+=(test&4)?"true":"false";
  out+=",\"index\":"; out+=String(test>>3); out+="}}";
  return out;
}
String makeState(uint32_t now) {
  bridgeLock();
  String out; out.reserve(4300);
  out="{\"firmware_version\":\""; out+=FIRMWARE_VERSION;
  out+="\",\"boot_id\":"; out+=String(bootId);
  out+=",\"linked\":"; out+=bridge.linked?"true":"false";
  out+=",\"synced\":"; out+=bridge.synced?"true":"false";
  out+=",\"stale\":"; out+=bridge.ready()?"false":"true";
  out+=",\"ack_age_ms\":";
  if(bridge.linked) out+=String(uint32_t(now-bridge.lastAck)); else out+="null";
  out+=",\"revision\":"; out+=String(bridge.revision);
  out+=",\"queued\":"; out+=String(bridge.queued);
  out+=",\"inflight\":"; out+=bridge.inflight?"true":"false";
  out+=",\"tx\":"; out+=String(bridge.txCount);
  out+=",\"rx\":"; out+=String(bridge.rxCount);
  out+=",\"raw_uart_rx_bytes\":"; out+=String(rawUartRxBytes);
  out+=",\"retries\":"; out+=String(bridge.retries);
  out+=",\"ignored\":"; out+=String(bridge.ignored);
  out+=",\"panic\":{\"requested\":"; out+=String(bridge.panicRequested);
  out+=",\"applied\":"; out+=String(bridge.panicApplied);
  out+=",\"failed\":"; out+=String(bridge.panicFailed);
  out+=",\"error\":"; out+=String(bridge.panicError);
  out+="},\"params\":{";
  for(uint8_t p=0;p<phone::COUNT;++p) {
    if(p) out+=',';
    out+='"'; out+=phone::KEYS[p]; out+="\":{\"value\":"; out+=String(bridge.values[p]);
    out+=",\"valid\":"; out+=bridge.valid[p]?"true":"false";
    out+=",\"requested\":"; out+=String(bridge.requested[p]);
    out+=",\"applied\":"; out+=String(bridge.applied[p]);
    out+=",\"failed\":"; out+=String(bridge.failed[p]);
    out+=",\"error\":"; out+=String(bridge.errors[p]); out+='}';
  }
  out+="},\"telemetry\":"; out+=telemetryJson(now); out+='}';
  bridgeUnlock();return out;
}
void stateRequest() {
  const String out=makeState(millis());
  headers(); server.send(200,"application/json; charset=utf-8",out);
}
void writeUsbStateChunk() {
  if(!usbStateReply.length()) return;
  const int freeBytes=Serial.availableForWrite();
  if(freeBytes<=0) return;
  size_t count=usbStateReply.length()-usbStateOffset;
  if(count>64) count=64;
  if(count>size_t(freeBytes)) count=size_t(freeBytes);
  usbStateOffset+=Serial.write(reinterpret_cast<const uint8_t*>(usbStateReply.c_str()+usbStateOffset),count);
  if(usbStateOffset==usbStateReply.length()) {
    usbStateReply=String(); usbStateOffset=0;
  }
}
void serviceUsbDiagnostic() {
  if(usbStateReply.length()){writeUsbStateChunk();return;}
  if(usbAwaiting){usbStateReply=usbPullAsync();if(usbStateReply.length()){usbAwaiting=false;usbStateOffset=0;writeUsbStateChunk();}return;}
  for(unsigned i=0;i<64 && Serial.available();++i){
    const int value=Serial.read();if(value<0)break;
    if(value=='\n'){
      if(!usbDiscardLine){
        if(usbCommandLength==5&&!memcmp(usbCommand,"STATE",5)){usbStateReply=makeState(millis());usbStateReply+='\n';}
        else usbStateReply=usbDispatchLine(usbCommand,usbCommandLength);
      }
      usbCommandLength=0;usbDiscardLine=false;usbStateOffset=0;break;
    }else if(!usbDiscardLine){
      if(usbCommandLength<sizeof(usbCommand))usbCommand[usbCommandLength++]=char(value);
      else{usbDiscardLine=true;usbCommandLength=0;}
    }
  }
  writeUsbStateChunk();
}
#include "v041_runtime.h"
void bridgeLock(){extension::lock();}
void bridgeUnlock(){extension::unlock();}
String usbDispatchLine(const char* s,size_t n){if(n==6&&!memcmp(s,"RECORD",6))return String("{\"recording\":")+extension::recordingJson()+"}\n";if((n>=3&&!memcmp(s,"EXT",3))||(n>=3&&!memcmp(s,"WAV",3)))return extension::usbDispatch(s,n);return "";}
String usbPullAsync(){return extension::usbPull();}
void setup() {
  // V039: CH340/USB uses UART0 for on-demand read-only STATE diagnostics.
  // UART2 is still the independent FPGA bridge; no startup/periodic app logs.
  Serial.setTxBufferSize(256);
  Serial.begin(115200);
  Serial.setDebugOutput(false);
  bootId=esp_random();
  fpgaUart.begin(1000000,FPGA_RX,FPGA_TX);
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(IPAddress(192,168,4,1),IPAddress(192,168,4,1),IPAddress(255,255,255,0));
  WiFi.softAP(AP_SSID,AP_PASSWORD);
  const char* collected[]={"Content-Type"}; server.collectHeaders(collected,1);
  server.on("/",HTTP_GET,[](){headers();server.send_P(200,"text/html; charset=utf-8",PHONE_HTML);});
  server.on("/api/state",HTTP_GET,stateRequest);
  server.on("/api/apply",HTTP_POST,applyParameters);
  server.on("/api/panic",HTTP_POST,panicRequest);
  server.onNotFound([](){jsonError(404,"接口不存在");});
  server.on("/extensions",HTTP_GET,[](){headers();server.send_P(200,"text/html; charset=utf-8",V041_HTML);});
  extension::routes();
  server.begin();
}
void loop() {
  // Dedicated UART task handles continuous RX, protocol demux and RPC scheduling.
  extension::fileService();
  serviceUsbDiagnostic();
  server.handleClient();
  delay(1);
}
