#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Portable core; no Arduino, allocation, serial enumeration or audio dependencies.
namespace phone {
static const uint8_t COUNT = 16, WRITABLE = 15, CAPACITY = 16;
static const uint32_t ACK_MS = 250, LINK_MS = 1500, PROBE_MS = 1000;
static const char* const KEYS[COUNT] = {
  "volume", "timbre", "input_mode", "fx_mode", "fx_wet", "fx_time",
  "fx_feedback", "fx_modulation", "attack", "decay", "sustain", "release",
  "hdmi_page", "filter", "digital_zero", "status_flags"
};
static const uint8_t LIMITS[COUNT] = {255,1,1,3,255,255,255,255,255,255,255,255,3,1,1,127};
inline uint8_t checksum(const uint8_t* b) {
  uint8_t x=0; for (uint8_t i=2;i<=10;++i) x^=b[i]; return x;
}
inline void request(uint8_t* b,uint8_t seq,uint8_t cmd,uint8_t p,uint8_t value) {
  memset(b,0,12); b[0]=0xA5; b[1]=0x5A; b[2]=1; b[3]=seq;
  b[4]=cmd; b[5]=p; b[6]=value; b[11]=checksum(b);
}

struct Parser {
  uint8_t bytes[12] = {}, used=0;
  uint32_t last=0;
  void reset() { used=0; }
  bool feed(uint8_t v,uint32_t now,uint8_t* out) {
    if (used && uint32_t(now-last)>=20) used=0;
    last=now;
    if (used==0) { if (v==0x5A) bytes[used++]=v; return false; }
    if (used==1) {
      if (v==0xA5) bytes[used++]=v;
      else used=(v==0x5A)?1:0;
      return false;
    }
    bytes[used++]=v;
    if (used<12) return false;
    bool good=bytes[2]==1 && bytes[11]==checksum(bytes);
    if (good) { memcpy(out,bytes,12); used=0; return true; }
    // Preserve a candidate header inside a noisy/bad frame.
    for (uint8_t i=1;i<11;++i) if (bytes[i]==0x5A && bytes[i+1]==0xA5) {
      used=12-i; memmove(bytes,bytes+i,used); return false;
    }
    used=bytes[11]==0x5A?1:0; if (used) bytes[0]=0x5A;
    return false;
  }
};

struct Values { bool has[WRITABLE]={}; uint8_t value[WRITABLE]={}; uint8_t count=0; };

// Strict flat JSON object parser. Parse into a temporary before any queue mutation.
// No arrays, nesting, escapes, floats/exponents, duplicate/unknown keys or booleans.
class PresetParser {
  const char* s; size_t n, i=0;
  void ws() { while(i<n && (s[i]==' ' || s[i]=='\r' || s[i]=='\n' || s[i]=='\t')) ++i; }
public:
  PresetParser(const char* text,size_t length):s(text),n(length){}
  bool parse(Values& out) {
    Values tmp;
    if (n>1024) return false;
    ws(); if(i>=n || s[i++]!='{') return false;
    ws(); if(i<n && s[i]=='}') return false;
    while(i<n) {
      ws(); if(i>=n || s[i++]!='"') return false;
      size_t start=i;
      while(i<n && s[i]!='"') {
        if ((s[i]<'a' || s[i]>'z') && s[i]!='_') return false;
        if(i-start>=24) return false;
        ++i;
      }
      if(i>=n) return false;
      size_t len=i-start; ++i;
      int p=-1;
      for(uint8_t k=0;k<WRITABLE;++k) if(strlen(KEYS[k])==len && !memcmp(s+start,KEYS[k],len)) p=k;
      if(p<0 || tmp.has[p]) return false;
      ws(); if(i>=n || s[i++]!=':') return false;
      ws(); if(i>=n || s[i]<'0' || s[i]>'9') return false;
      bool zero=s[i]=='0'; unsigned v=0, digits=0;
      while(i<n && s[i]>='0' && s[i]<='9') {
        if(++digits>3 || (zero && digits>1)) return false;
        v=v*10+unsigned(s[i++]-'0');
      }
      if(v>LIMITS[p]) return false;
      tmp.has[p]=true; tmp.value[p]=uint8_t(v); ++tmp.count;
      ws(); if(i>=n) return false;
      char c=s[i++]; if(c=='}') { ws(); if(i!=n) return false; out=tmp; return true; }
      if(c!=',') return false;
    }
    return false;
  }
};

struct Item { uint8_t cmd=0,param=0,value=0; uint32_t revision=0; };
typedef void (*Send)(const uint8_t*,size_t,void*);
struct Core {
  Send send; void* context;
  Parser parser;
  uint8_t values[COUNT]={}; bool valid[COUNT]={};
  uint32_t requested[COUNT]={}, applied[COUNT]={}, failed[COUNT]={};
  uint8_t errors[COUNT]={}; // 1..4 FPGA; 10 timeout, 11 Panic cancel, 12 actual != target
  Item queue[CAPACITY], current;
  uint8_t queued=0, seq=0, frame[12]={}, attempts=0, scan=0;
  bool inflight=false, linked=false, synced=false;
  uint32_t revision=0, panicRequested=0, panicApplied=0, panicFailed=0;
  uint8_t panicError=0;
  uint32_t sentAt=0,lastAck=0,lastProbe=0,lastPoll=0,lastVolume=0;
  bool probeStarted=false;
  uint32_t txCount=0,rxCount=0,retries=0,ignored=0;
  Core(Send fn,void* ctx=0):send(fn),context(ctx){}
  uint32_t nextRevision() { if(++revision==0) ++revision; return revision; }
  void fail(const Item& item,uint8_t error) {
    if(!item.revision) return;
    if(item.cmd==2) { panicFailed=item.revision; panicError=error; }
    else { failed[item.param]=item.revision; errors[item.param]=error; }
  }
  void disconnect(uint32_t now) {
    if(inflight) fail(current,10);
    for(uint8_t i=0;i<queued;++i) fail(queue[i],10);
    queued=0; inflight=false; linked=false; synced=false;
    memset(valid,0,sizeof(valid)); parser.reset(); scan=0;
    lastProbe=now; probeStarted=true;
  }
  bool ready() const { return linked && synced; }
  bool enqueue(const Values& batch,uint32_t& rev) {
    if(!ready() || !batch.count) return false;
    // Defensively validate even callers that bypass the JSON parser.
    uint8_t needed=0, count=0;
    for(uint8_t p=0;p<WRITABLE;++p) if(batch.has[p]) {
      ++count; if(batch.value[p]>LIMITS[p]) return false;
      bool found=false;
      for(uint8_t i=0;i<queued;++i) if(queue[i].cmd==1 && queue[i].param==p) found=true;
      if(!found) ++needed;
    }
    if(count!=batch.count || queued+needed>CAPACITY) return false;
    rev=nextRevision();
    for(uint8_t p=0;p<WRITABLE;++p) if(batch.has[p]) {
      uint8_t slot=queued;
      for(uint8_t i=0;i<queued;++i) if(queue[i].cmd==1 && queue[i].param==p) {slot=i; break;}
      Item item; item.cmd=1; item.param=p; item.value=batch.value[p]; item.revision=rev;
      queue[slot]=item; if(slot==queued) ++queued;
      requested[p]=rev;
    }
    return true;
  }
  bool panic(uint32_t& rev) {
    if(!ready()) return false;
    for(uint8_t i=0;i<queued;++i) fail(queue[i],11);
    queued=0; rev=nextRevision(); panicRequested=rev;
    Item item; item.cmd=2; item.revision=rev; queue[queued++]=item;
    return true;
  }
  void start(const Item& item,uint32_t now) {
    current=item; request(frame,seq++,item.cmd,item.param,item.value);
    inflight=true; attempts=1; sentAt=now;
    send(frame,12,context); ++txCount;
  }
  bool acceptable(const uint8_t* b) const {
    if(b[0]!=0x5A || b[1]!=0xA5 || b[2]!=1 || b[11]!=checksum(b)) return false;
    if(!inflight || b[3]!=frame[3] || b[5]!=current.param || b[4]>4) return false;
    if(b[7]&0x80 || b[8]>1 || b[9]>3) return false;
    if(b[4]==0 && (b[5]>=COUNT || b[6]>LIMITS[b[5]])) return false;
    return true;
  }
  void receive(uint8_t v,uint32_t now) {
    uint8_t b[12]; if(!parser.feed(v,now,b)) return;
    if(!acceptable(b)) {++ignored; return;}
    ++rxCount; lastAck=now; linked=true;
    values[0]=b[10]; values[1]=b[8]; values[3]=b[9]; values[15]=b[7];
    valid[0]=valid[1]=valid[3]=valid[15]=true;
    if(b[4]==0) {
      // Panic PARAM=0 also reports the effective master volume.
      values[b[5]]=b[6]; valid[b[5]]=true;
      if(current.revision) {
        if(current.cmd==2) panicApplied=current.revision;
        else if(current.cmd==1 && b[6]!=current.value) fail(current,12);
        else applied[current.param]=current.revision;
      }
    } else fail(current,b[4]);
    inflight=false;
    synced=true; for(uint8_t p=0;p<COUNT;++p) if(!valid[p]) synced=false;
  }
  void tick(uint32_t now) {
    if(linked && uint32_t(now-lastAck)>=LINK_MS) { disconnect(now); return; }
    if(inflight) {
      if(uint32_t(now-sentAt)>=ACK_MS) {
        if(attempts<3) {++attempts; ++retries; sentAt=now; send(frame,12,context); ++txCount;}
        else disconnect(now);
      }
      return;
    }
    if(!linked) {
      if(!probeStarted || uint32_t(now-lastProbe)>=PROBE_MS) {
        probeStarted=true; lastProbe=now; Item get; get.param=15; start(get,now);
      }
      return;
    }
    if(queued) {
      Item next=queue[0]; for(uint8_t i=1;i<queued;++i) queue[i-1]=queue[i];
      --queued; start(next,now); return;
    }
    // Never enqueue polling requests. Writes always win at this boundary.
    if(!synced) {
      for(uint8_t p=0;p<COUNT;++p) if(!valid[p]) {Item get; get.param=p; start(get,now); return;}
    }
    if(uint32_t(now-lastPoll)<120) return;
    Item get;
    if(uint32_t(now-lastVolume)>=500) {get.param=0; lastVolume=now;}
    else {get.param=scan; scan=(scan+1)%COUNT;}
    lastPoll=now; start(get,now);
  }
};
} // namespace phone
