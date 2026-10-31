#pragma once
struct IPAddress { IPAddress(int,int,int,int){} };
static const int WIFI_AP=1;
struct MockWiFi {
  void mode(int){}
  void softAPConfig(IPAddress,IPAddress,IPAddress){}
  void softAP(const char*,const char*){}
};
static MockWiFi WiFi;
