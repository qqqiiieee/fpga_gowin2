#include <cassert>
#include <cstdio>
#include <vector>
#include <cstring>
#include <string>
#include "../esp32_phone/v041_core.h"
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x)){std::fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;}}while(0)
static bool collect(const uint8_t* p,size_t n,void* c){auto& v=*static_cast<std::vector<uint8_t>*>(c);v.insert(v.end(),p,p+n);return true;}
static bool reject(const uint8_t*,size_t,void*){return false;}
static void frame(uint8_t* b,uint8_t result,uint8_t seq){memset(b,0,12);b[0]=0x5A;b[1]=0xA5;b[2]=1;b[3]=seq;b[4]=result;}
static void seal(uint8_t* b){b[11]=phone::checksum(b);}
int main(){
 v041::UsbCommand usb;
 CHECK(v041::parseUsb("STATE",5,usb)&&usb.kind==v041::UsbCommand::STATE_LINE);
 CHECK(v041::parseUsb("EXT 16 0102030405",17,usb)&&usb.op==16&&usb.payload[0]==5&&usb.payload[4]==1);
 CHECK(v041::parseUsb("EXT 38 0000000000",17,usb)&&usb.op==38);
 CHECK(v041::parseUsb("WAV 937032 512",14,usb)&&usb.offset==937032&&usb.count==512);
 const char* malformed[]={"EXT 256 0000000000","EXT -1 0000000000","EXT 1 000000000","EXT 1 00000000000","EXT 1 000000000g","WAV /last.wav 4","WAV 0 513","WAV 0 0","WAV 4294967296 1","STATE\r"};
 for(const char* line:malformed)CHECK(!v041::parseUsb(line,strlen(line),usb));
 uint32_t c=0xFFFFFFFFu;for(char x:std::string("123456789"))c=v041::crcByte(c,uint8_t(x));CHECK((c^0xFFFFFFFFu)==0xCBF43926u);
 const char* error="";v041::Score s;s.count=2;s.events[0]={60,96,0,4};s.events[1]={60,80,4,8};CHECK(s.build(error));
 CHECK(s.total==20&&s.beatSamples==46875);CHECK(!(s.words[0]&(1u<<13))&&(s.words[0]&(1u<<23)));CHECK(((s.words[0]>>16)&127)==60);
 CHECK((s.words[8]&(1u<<14))&&(s.words[12]&(1u<<14)));CHECK(((s.words[12]>>7)&63)==1);CHECK(s.words[12]&(1u<<15));CHECK(!(s.words[13]&(1u<<14)));CHECK(!(s.words[19]&(1u<<23)));
 uint16_t sum=0;for(unsigned q=0;q<s.total;++q)for(unsigned b=0;b<4;++b)sum=uint16_t(sum+uint8_t(s.words[q]>>(b*8)));CHECK(sum==s.sum);
 s.bpm=240;CHECK(s.build(error)&&s.beatSamples==23438);s.bpm=30;CHECK(s.build(error)&&s.beatSamples==187500);s.bpm=29;CHECK(!s.build(error));s.bpm=120;
 s.events[1].start=3;CHECK(!s.build(error));s.events[1].start=4;s.events[0].pitch=40;CHECK(!s.build(error));s.events[0].pitch=73;CHECK(!s.build(error));s.events[0].pitch=41;s.events[0].velocity=0;CHECK(!s.build(error));
 v041::Score edge;edge.count=63;for(unsigned i=0;i<63;++i)edge.events[i]={uint8_t(41+i%32),127,uint16_t(i*3),3};edge.melodyQuarters=244;CHECK(edge.build(error)&&edge.total==252);for(unsigned i=0;i<edge.total;++i)CHECK(!(edge.words[i]>>31));
 v041::Mapping m;CHECK(m.validate(error));CHECK(m.pads[0]==36&&m.pads[1]==38&&m.pads[2]==37&&m.pads[3]==39);CHECK(m.cc[0]==93&&m.cc[1]==91&&m.cc[2]==71&&m.cc[3]==74);
 uint8_t tmp=m.notes[0];m.notes[0]=m.notes[127];m.notes[127]=tmp;CHECK(m.validate(error));m.notes[2]=m.notes[1];CHECK(!m.validate(error));m.defaults();m.cc[0]=64;CHECK(!m.validate(error));m.defaults();m.pads[0]=m.pads[1];CHECK(!m.validate(error));
 for(int cc: {1,7,64,120,121,123}){m.defaults();m.cc[0]=cc;CHECK(!m.validate(error));}
 v041::Rpc r;uint8_t d[5]={63,252,0x1B,0xB7,0};r.begin(255,v041::SCORE_BEGIN,d,100);uint8_t original[12];memcpy(original,r.frame,12);CHECK(r.frame[4]==3&&r.frame[6]==63&&r.frame[11]==phone::checksum(r.frame));CHECK(!r.tick(599));CHECK(r.tick(600));CHECK(!memcmp(original,r.frame,12));CHECK(r.tick(1100));CHECK(!r.tick(1600)&&r.done&&!r.ok&&r.error==10);
 uint8_t b[12];r.begin(7,v041::MAP_COMMIT,d,0);frame(b,0x20,8);b[5]=v041::MAP_COMMIT;seal(b);CHECK(!r.receive(b));b[3]=7;seal(b);b[11]^=1;CHECK(!r.receive(b));seal(b);CHECK(r.receive(b)&&r.ok);
 r.begin(8,v041::MAP_COMMIT,d,0);frame(b,0x21,8);b[5]=v041::MAP_COMMIT;b[6]=3;seal(b);CHECK(r.receive(b)&&!r.ok&&r.error==3);
 // All possible EOF tail lengths. Padding must never reach PCM, CRC or WAV.
 for(unsigned first=0;first<256;++first)for(unsigned count=0;count<12;++count){std::vector<uint8_t> bytes;v041::Audio a(collect,&bytes);a.reset();uint32_t expected=0xFFFFFFFFu;
  for(unsigned i=0;i<(count+2)/3;++i){frame(b,0x40,uint8_t(first+i));for(unsigned k=0;k<3;++k){uint16_t sample=uint16_t((i*3+k)*257);v041::put16(b+5+k*2,sample);if(i*3+k<count){expected=v041::crcByte(expected,uint8_t(sample));expected=v041::crcByte(expected,uint8_t(sample>>8));}}seal(b);a.receive(b);}
  frame(b,0x41,uint8_t(first+(count+2)/3));v041::put32(b+5,count);seal(b);a.receive(b);CHECK(a.verify(expected^0xFFFFFFFFu));CHECK(bytes.size()==count*2&&a.samples==count);uint8_t h[44];v041::wavHeader(h,count);CHECK(v041::le32(h+24)==15625&&v041::le32(h+40)==count*2&&v041::le32(h+4)==count*2+36);
 }
 std::vector<uint8_t> bytes;v041::Audio a(collect,&bytes);a.reset();frame(b,0x40,254);seal(b);a.receive(b);CHECK(!a.bad);b[3]=0;seal(b);a.receive(b);CHECK(a.bad);a.reset();frame(b,0x40,0);seal(b);b[11]^=1;a.receive(b);CHECK(a.bad);
 // Sequence is global across recordings, not reset by REC_START or ESP reset.
 uint8_t seq=253;for(unsigned session=0;session<8;++session){bytes.clear();a.reset();uint32_t crc=0xFFFFFFFFu;for(unsigned i=0;i<2;++i){frame(b,0x40,seq++);for(unsigned k=0;k<6;++k){b[k+5]=uint8_t(session+i+k);crc=v041::crcByte(crc,b[k+5]);}seal(b);a.receive(b);}frame(b,0x41,seq++);v041::put32(b+5,6);seal(b);a.receive(b);CHECK(a.verify(crc^0xFFFFFFFFu)&&bytes.size()==12);}
 // Duplicates and a wrong EOF sequence are still failures after learning start.
 a.reset();frame(b,0x40,91);seal(b);a.receive(b);a.receive(b);CHECK(a.bad);
 a.reset();frame(b,0x40,91);seal(b);a.receive(b);frame(b,0x41,93);v041::put32(b+5,3);seal(b);a.receive(b);CHECK(a.bad);
 // Dropped first packet: learned start looks valid but EOF sample count rejects.
 a.reset();frame(b,0x40,92);seal(b);a.receive(b);frame(b,0x41,93);v041::put32(b+5,6);seal(b);a.receive(b);CHECK(a.bad);
 a.reset();frame(b,0x41,0);v041::put32(b+5,3);seal(b);a.receive(b);CHECK(a.bad);a.reset();frame(b,0x41,0);b[9]=1;seal(b);a.receive(b);CHECK(a.bad);
 v041::Audio overflow(reject,nullptr);overflow.reset();frame(b,0x40,0);seal(b);overflow.receive(b);b[3]=1;seal(b);overflow.receive(b);CHECK(overflow.bad);
 // A loss of 256 frames can hide in SEQ; EOF count must still invalidate it.
 a.reset();frame(b,0x40,0);seal(b);a.receive(b);frame(b,0x41,1);v041::put32(b+5,771);seal(b);a.receive(b);CHECK(a.bad);
 // 30 seconds: full stream, sequence wraps 610 times, exact file and CRC.
 bytes.clear();a.reset();uint32_t expected=0xFFFFFFFFu;for(unsigned i=0;i<156250;++i){frame(b,0x40,uint8_t(i+77));for(unsigned k=0;k<6;++k){b[5+k]=uint8_t(i+k);expected=v041::crcByte(expected,b[5+k]);}seal(b);a.receive(b);}frame(b,0x41,uint8_t(156250+77));v041::put32(b+5,468750);seal(b);a.receive(b);CHECK(a.verify(expected^0xFFFFFFFFu)&&bytes.size()==937500);CHECK(!a.verify(expected));uint8_t h[44];v041::wavHeader(h,a.count);CHECK(v041::le32(h+4)+8==937544);
 // Ordinary parameter heartbeat cannot be refreshed by the audio frame result.
 phone::Core bridge(nullptr);bridge.inflight=true;bridge.frame[3]=0;bridge.current.param=0;frame(b,0x40,0);seal(b);for(auto x:b)bridge.receive(x,1000);CHECK(!bridge.linked&&bridge.lastAck==0&&bridge.rxCount==0);
 bridge.disconnect(2000);CHECK(!bridge.ready()&&!bridge.inflight&&!bridge.telemetry.valid);
 phone::Parser parser;frame(b,0x20,2);seal(b);uint8_t out[12];bool parsed=false;for(auto x:b)parsed=parser.feed(x,0,out)||parsed;CHECK(parsed&&!memcmp(b,out,12));parser.reset();for(unsigned i=0;i<6;++i)parser.feed(b[i],0,out);CHECK(!parser.feed(b[6],30,out));
 std::printf("V041_ESP_PORTABLE_PASS checks=%u full30s=468750 tails=0,1,2 retry_idempotent=1 bad_frames=1 disconnect=1\n",checks);return 0;
}
