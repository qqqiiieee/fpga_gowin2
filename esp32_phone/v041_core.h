#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "bridge_core.h"

// Portable implementation of docs/phone_extensions_protocol.json, not the plan.
namespace v041 {
enum Op : uint8_t { CAP=0, STATE=1, SCORE_BEGIN=16, SCORE_WRITE=17,
 SCORE_COMMIT=18, SCORE_CANCEL=19, GUIDE_CONTROL=20, MAP_BEGIN=32, NOTE_WRITE=33,
 PAD_WRITE=34, CC_WRITE=35, MAP_COMMIT=36, MAP_CANCEL=37, MAP_DISABLE=38,
 REC_START=48, REC_STOP=49, REC_CRC=50, REC_STATE=51 };
inline uint32_t le32(const uint8_t* p) {return uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24);}
inline void put32(uint8_t* p,uint32_t n){for(unsigned i=0;i<4;++i)p[i]=uint8_t(n>>(8*i));}
inline void put16(uint8_t* p,uint16_t n){p[0]=uint8_t(n);p[1]=uint8_t(n>>8);}
inline uint32_t crcByte(uint32_t c,uint8_t b){c^=b;for(unsigned i=0;i<8;++i)c=(c>>1)^((c&1)?0xEDB88320u:0);return c;}
struct Event {uint8_t pitch,velocity;uint16_t start,duration;uint8_t offsets[3];};
struct Score {
 Event events[63]{};uint8_t count=0;uint16_t bpm=120,melodyQuarters=0,total=0,sum=0;
 uint32_t beatSamples=46875,words[256]{};bool hasChords=false;
 bool build(const char*& error){
  if(!count||count>63||bpm<30||bpm>240){error="事件须1..63，BPM须30..240";return false;}
  uint32_t end=0;hasChords=false;
  for(unsigned i=0;i<count;++i){const Event& e=events[i];
   if(e.pitch<41||e.pitch>72||!e.velocity||e.velocity>127||!e.duration||e.start<end||uint32_t(e.start)+e.duration>244){error="音高须F2..C5(41..72)，力度/时值须合法且各音组不重叠";return false;}
   uint8_t last=0;bool absent=false;
   for(unsigned j=0;j<3;++j){uint8_t d=e.offsets[j];if(!d){absent=true;continue;}
    if(absent||d<=last||d>31||unsigned(e.pitch)+d>72){error="和弦须1..4个升序唯一音高41..72";return false;}
    last=d;hasChords=true;
   }
   end=uint32_t(e.start)+e.duration;
  }
  if(!melodyQuarters)melodyQuarters=uint16_t(end);
  if(melodyQuarters<end||melodyQuarters>244){error="总时值不足或含两拍预备后超过63拍";return false;}
  total=melodyQuarters+8;beatSamples=(5625000u+bpm/2)/bpm;
  memset(words,0,sizeof(words));sum=0;
  for(unsigned q=0;q<total;++q){
   int current=-1,next=-1;unsigned step=0;
   for(unsigned i=0;i<count;++i){const Event& e=events[i];unsigned start=e.start+8;
    if(q>=start&&q<start+e.duration){current=int(i);step=i;}
    if(start>q&&next<0)next=int(i);
   }
   uint32_t w=0;
   if(current>=0){const Event& e=events[current];
    w=e.pitch|(uint32_t(step)<<7)|(1u<<13)|((q==unsigned(e.start)+8u)?1u<<14:0)|((e.duration>4)?1u<<15:0)|(uint32_t(e.velocity)<<24);
    next=current+1<count?current+1:-1;
    if(e.offsets[0])w=(w&0xFFFFu)|0x80000000u|(uint32_t(e.offsets[0])<<16)|(uint32_t(e.offsets[1])<<21)|(uint32_t(e.offsets[2])<<26);
   }
   if(next>=0 && !(w&0x80000000u))w|=(uint32_t(events[next].pitch)<<16)|(1u<<23);
   words[q]=w;for(unsigned b=0;b<4;++b)sum=uint16_t(sum+uint8_t(w>>(8*b)));
  }
  return true;
 }
};
struct Mapping {
 uint8_t notes[128],pads[4],cc[4];uint16_t sum=0;
 Mapping(){defaults();}
 void defaults(){for(unsigned i=0;i<128;++i)notes[i]=uint8_t(i);const uint8_t p[4]={36,38,37,39},c[4]={93,91,71,74};memcpy(pads,p,4);memcpy(cc,c,4);}
 bool validate(const char*& error){
  bool seen[128]={};sum=0;
  for(unsigned i=0;i<128;++i){if(notes[i]>127||seen[notes[i]]){error="Note映射须为0..127的单射，避免同音松键冲突";return false;}seen[notes[i]]=true;sum=uint16_t(sum+i+notes[i]);}
  for(unsigned i=0;i<4;++i){if(pads[i]>127||cc[i]>127||cc[i]==1||cc[i]==7||cc[i]==64||cc[i]==120||cc[i]==121||cc[i]==123){error="Pad/CC越界或占用保护CC";return false;}for(unsigned j=0;j<i;++j)if(pads[i]==pads[j]||cc[i]==cc[j]){error="四Pad/CC来源不能重复";return false;}sum=uint16_t(sum+i+pads[i]+i+cc[i]);}
  return true;
 }
};
struct Rpc {
 uint8_t frame[12]{},attempts=0,status=0,error=0;uint32_t reply=0,sentAt=0,retries=0,ignored=0;
 bool inflight=false,done=false,ok=false;
 void begin(uint8_t seq,uint8_t op,const uint8_t data[5],uint32_t now){
  memset(frame,0,12);frame[0]=0xA5;frame[1]=0x5A;frame[2]=1;frame[3]=seq;frame[4]=3;frame[5]=op;
  memcpy(frame+6,data,5);frame[11]=phone::checksum(frame);attempts=1;sentAt=now;inflight=true;done=ok=false;error=0;
 }
 bool receive(const uint8_t b[12]){
  if(!inflight||b[2]!=1||b[3]!=frame[3]||b[5]!=frame[5]||(b[4]!=0x20&&b[4]!=0x21)||b[11]!=phone::checksum(b)){++ignored;return false;}
  status=b[6];reply=le32(b+7);ok=b[4]==0x20&&b[6]==0;error=ok?0:b[6];done=true;inflight=false;return true;
 }
 // Retry EXACT bytes/seq/op/payload. New operations must use a new sequence.
 bool tick(uint32_t now,uint32_t timeout=500){
  if(!inflight||uint32_t(now-sentAt)<timeout)return false;
  if(attempts<3){++attempts;++retries;sentAt=now;return true;}
  inflight=false;done=true;ok=false;error=10;return false;
 }
};
struct UsbCommand {enum Kind{UNKNOWN,STATE_LINE,EXT_LINE,WAV_LINE}kind=UNKNOWN;uint8_t op=0,payload[5]{};uint32_t offset=0,count=0;};
inline bool usbNumber(const char* s,size_t n,size_t& pos,uint32_t& value){size_t begin=pos;value=0;while(pos<n&&s[pos]>='0'&&s[pos]<='9'){unsigned d=unsigned(s[pos++]-'0');if(value>(0xFFFFFFFFu-d)/10)return false;value=value*10+d;}return pos>begin;}
inline bool parseUsb(const char* s,size_t n,UsbCommand& out){
 out=UsbCommand();if(n==5&&!memcmp(s,"STATE",5)){out.kind=UsbCommand::STATE_LINE;return true;}
 if(n>4&&!memcmp(s,"EXT ",4)){size_t pos=4;uint32_t op=0;if(!usbNumber(s,n,pos,op)||op>255||pos>=n||s[pos++]!=' '||n-pos!=10)return false;uint64_t bits=0;for(;pos<n;++pos){char c=s[pos];unsigned d=c>='0'&&c<='9'?unsigned(c-'0'):c>='a'&&c<='f'?unsigned(c-'a'+10):c>='A'&&c<='F'?unsigned(c-'A'+10):16;if(d>15)return false;bits=(bits<<4)|d;}out.kind=UsbCommand::EXT_LINE;out.op=uint8_t(op);for(unsigned i=0;i<5;++i)out.payload[i]=uint8_t(bits>>(i*8));return true;}
 if(n>4&&!memcmp(s,"WAV ",4)){size_t pos=4;if(!usbNumber(s,n,pos,out.offset)||pos>=n||s[pos++]!=' '||!usbNumber(s,n,pos,out.count)||pos!=n||out.count<1||out.count>512)return false;out.kind=UsbCommand::WAV_LINE;return true;}return false;
}
inline void wavHeader(uint8_t h[44],uint32_t samples){
 memset(h,0,44);memcpy(h,"RIFF",4);put32(h+4,36+samples*2);memcpy(h+8,"WAVEfmt ",8);put32(h+16,16);
 put16(h+20,1);put16(h+22,1);put32(h+24,15625);put32(h+28,31250);put16(h+32,2);put16(h+34,16);memcpy(h+36,"data",4);put32(h+40,samples*2);
}
typedef bool (*Sink)(const uint8_t*,size_t,void*);
struct Audio {
 Sink sink;void* context;bool active=false,eof=false,bad=false,haveTail=false,haveSeq=false;
 uint8_t tail[6]{},nextSeq=0;uint32_t frames=0,samples=0,count=0,crc=0xFFFFFFFFu;uint16_t drops=0;const char* error="";
 Audio(Sink s,void* c):sink(s),context(c){}
 void reset(){active=true;eof=bad=haveTail=haveSeq=false;nextSeq=0;frames=samples=count=0;crc=0xFFFFFFFFu;drops=0;error="";}
 void fail(const char* why){if(!bad)error=why;bad=true;} // Preserve the root cause.
 bool append(const uint8_t* b,unsigned n){
  if(samples+n>468750){fail("超过30秒样本上限");return false;}
  if(!sink(b,n*2,context)){fail("ESP PCM写缓冲溢出");return false;}
  for(unsigned i=0;i<n*2;++i)crc=crcByte(crc,b[i]);samples+=n;return true;
 }
 void receive(const uint8_t b[12]){
  if(!active||eof)return;
  if(b[11]!=phone::checksum(b)){fail("音频帧XOR错误");return;}
  if(b[4]==0x40){
   // FPGA audio_seq is global until FPGA reset, including EOF packets. Learn
   // the first sequence of EACH recording (ESP-only reset must also work).
   // Subsequent packets, including EOF, must be contiguous modulo 256. EOF
   // count and final PCM CRC still detect a missing first packet/prefix.
   if(haveSeq&&b[3]!=nextSeq)fail("音频SEQ缺帧/重复/乱序");
   haveSeq=true;nextSeq=uint8_t(b[3]+1);
   if(haveTail)append(tail,3);memcpy(tail,b+5,6);haveTail=true;++frames;
   if(frames>156250)fail("音频帧数超过30秒上限");
  }else if(b[4]==0x41){
   if(haveSeq&&b[3]!=nextSeq)fail("音频EOF序号不连续");
   count=le32(b+5);drops=uint16_t(b[9])|(uint16_t(b[10])<<8);
   if(count>468750||frames!=(count+2)/3||drops)fail("EOF样本/帧计数或FPGA丢样本不符");
   if(haveTail){unsigned n=count%3;if(!n&&count)n=3;append(tail,n);}
   if(samples!=count)fail("实际PCM字节数与EOF不符");
   eof=true;active=false;
  }
 }
 uint32_t finalCrc()const{return crc^0xFFFFFFFFu;}
 bool verify(uint32_t remote){if(!eof||remote!=finalCrc())fail("REC_CRC与本地PCM CRC不符");return eof&&!bad;}
};
} // namespace v041
