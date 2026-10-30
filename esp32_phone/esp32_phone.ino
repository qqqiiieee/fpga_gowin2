#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include "bridge_core.h"
#include "web_ui.h"

// Change these two strings to rename/protect your own AP (password >=8 bytes).
static const char AP_SSID[] = "Tang20K-Music";
static const char AP_PASSWORD[] = "fpga2026";
static const int FPGA_RX = 16; // ESP RX2 <- FPGA PMOD3 N8 TX
static const int FPGA_TX = 17; // ESP TX2 -> FPGA PMOD3 L9 RX
HardwareSerial fpgaUart(2);
WebServer server(80);
void uartSend(const uint8_t* bytes,size_t length,void*) { fpgaUart.write(bytes,length); }
phone::Core bridge(uartSend);
uint32_t bootId=0;

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
  if(!bridge.ready()) { jsonError(503,"FPGA 状态过期或正在恢复回读，未接受写入"); return; }
  uint32_t rev;
  if(!bridge.enqueue(batch,rev)) {jsonError(429,"队列已满，未接受任何参数"); return;}
  accepted(rev); // accepted is not an FPGA acknowledgement.
}
void panicRequest() {
  if(!jsonBody()) return;
  if(server.arg("plain")!="{}") {jsonError(400,"Panic 只接受空对象 {}");return;}
  uint32_t rev;
  if(!bridge.panic(rev)) {jsonError(503,"FPGA 断链或正在回读，Panic 未发送");return;}
  accepted(rev);
}
void stateRequest() {
  String out; out.reserve(3200);
  out="{\"boot_id\":"; out+=String(bootId);
  out+=",\"linked\":"; out+=bridge.linked?"true":"false";
  out+=",\"synced\":"; out+=bridge.synced?"true":"false";
  out+=",\"stale\":"; out+=bridge.ready()?"false":"true";
  out+=",\"ack_age_ms\":";
  if(bridge.linked) out+=String(uint32_t(millis()-bridge.lastAck)); else out+="null";
  out+=",\"revision\":"; out+=String(bridge.revision);
  out+=",\"queued\":"; out+=String(bridge.queued);
  out+=",\"inflight\":"; out+=bridge.inflight?"true":"false";
  out+=",\"tx\":"; out+=String(bridge.txCount);
  out+=",\"rx\":"; out+=String(bridge.rxCount);
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
  out+="}}"; headers(); server.send(200,"application/json; charset=utf-8",out);
}
void setup() {
  // USB supplies power only; never start/open the USB debug serial port.
  bootId=esp_random();
  fpgaUart.setRxBufferSize(256);
  fpgaUart.begin(115200,SERIAL_8N1,FPGA_RX,FPGA_TX);
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(IPAddress(192,168,4,1),IPAddress(192,168,4,1),IPAddress(255,255,255,0));
  WiFi.softAP(AP_SSID,AP_PASSWORD);
  const char* collected[]={"Content-Type"}; server.collectHeaders(collected,1);
  server.on("/",HTTP_GET,[](){headers();server.send_P(200,"text/html; charset=utf-8",PHONE_HTML);});
  server.on("/api/state",HTTP_GET,stateRequest);
  server.on("/api/apply",HTTP_POST,applyParameters);
  server.on("/api/panic",HTTP_POST,panicRequest);
  server.onNotFound([](){jsonError(404,"接口不存在");});
  server.begin();
}
void loop() {
  // Drain ACK before scheduling a retry; bounded work keeps WebServer responsive.
  for(unsigned i=0;i<256 && fpgaUart.available();++i) bridge.receive(uint8_t(fpgaUart.read()),millis());
  bridge.tick(millis());
  server.handleClient();
  yield();
}
