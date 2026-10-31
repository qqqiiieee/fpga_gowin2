#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string>
#include <type_traits>
#include <deque>
#include <vector>
class String {
  std::string value;
public:
  String()=default;
  String(const char* s):value(s){}
  String(const std::string& s):value(s){}
  template<class T,typename std::enable_if<std::is_arithmetic<T>::value,int>::type=0>
  String(T v):value(std::to_string(v)){}
  const char* c_str()const{return value.c_str();}
  size_t length()const{return value.size();}
  void reserve(size_t n){value.reserve(n);}
  String& operator+=(const String& s){value+=s.value;return *this;}
  String& operator+=(const char* s){value+=s;return *this;}
  String& operator+=(char c){value+=c;return *this;}
  bool operator==(const char* s)const{return value==s;}
  bool operator==(const String& s)const{return value==s.value;}
  bool operator!=(const char* s)const{return value!=s;}
  friend String operator+(String a,const String& b){a+=b;return a;}
};
static uint32_t fakeMillis=0;
inline uint32_t millis(){return fakeMillis;}
inline uint32_t esp_random(){return 321;}
inline void yield(){}
static const int SERIAL_8N1=0;
class HardwareSerial {
public:
  int baud=0,rx=-1,tx=-1;
  size_t txBufferSize=0;
  bool debugOutput=true;
  bool failNextRead=false;
  int txSpace=128;
  unsigned wouldBlockWrites=0;
  std::deque<uint8_t> input;
  std::vector<uint8_t> output;
  HardwareSerial(int){}
  size_t write(const uint8_t* bytes,size_t length){
    if(length>size_t(txSpace)){++wouldBlockWrites;return 0;}
    output.insert(output.end(),bytes,bytes+length);txSpace-=int(length);return length;
  }
  int availableForWrite(){return txSpace;}
  void setTxBufferSize(size_t n){txBufferSize=n;}
  void setDebugOutput(bool enabled){debugOutput=enabled;}
  void setRxBufferSize(size_t){}
  void begin(int b,int=SERIAL_8N1,int r=-1,int t=-1){baud=b;rx=r;tx=t;}
  int available(){return int(input.size());}
  int read(){if(failNextRead){failNextRead=false;return -1;}if(input.empty())return -1;auto value=input.front();input.pop_front();return value;}
  void inject(const std::string& text){for(unsigned char c:text)input.push_back(c);}
};
static HardwareSerial Serial(0);
