#pragma once
#include <Arduino.h>
#include <map>
#define PROGMEM
enum {HTTP_GET,HTTP_POST};
class WebServer {
public:
  int status=0; String response;
  std::map<std::string,String> arguments;
  WebServer(int){}
  void sendHeader(const char*,const char*){}
  void send(int code,const char*,const String& body){status=code;response=body;}
  void send_P(int code,const char*,const char* body){status=code;response=body;}
  String header(const char*){return "application/json";}
  bool hasArg(const char* key){return arguments.count(key)!=0;}
  String arg(const char* key){return arguments[key];}
  void collectHeaders(const char**,size_t){}
  template<class F>void on(const char*,int,F){}
  template<class F>void onNotFound(F){}
  void begin(){}
  void handleClient(){}
};
