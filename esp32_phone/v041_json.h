#pragma once
#include <Arduino.h>
#include <math.h>
#include <cJSON.h>
#include "v041_core.h"
namespace v041 {
inline bool integer(const cJSON* x,int lo,int hi,int& out){if(!cJSON_IsNumber(x)||!isfinite(x->valuedouble)||floor(x->valuedouble)!=x->valuedouble||x->valuedouble<lo||x->valuedouble>hi)return false;out=int(x->valuedouble);return true;}
inline cJSON* item(cJSON* o,const char* k){return cJSON_GetObjectItemCaseSensitive(o,k);}
inline bool cleanTree(cJSON* n,unsigned depth=0){
 if(depth>8)return false;
 if(cJSON_IsObject(n))for(cJSON* a=n->child;a;a=a->next){for(cJSON* b=a->next;b;b=b->next)if(!strcmp(a->string,b->string))return false;}
 for(cJSON* a=n->child;a;a=a->next)if(!cleanTree(a,depth+1))return false;return true;
}
inline cJSON* parse(const String& text,size_t max,const char*& error){
 if(!text.length()||text.length()>max){error="JSON为空或超过大小限制";return nullptr;}
 bool str=false,esc=false;int depth=0;
 for(unsigned i=0;i<text.length();++i){char c=text[i];if(str){if(esc)esc=false;else if(c=='\\')esc=true;else if(c=='\"')str=false;}else{if(c=='\"')str=true;else if(c=='{'||c=='['){if(++depth>8){error="JSON嵌套过深";return nullptr;}}else if(c=='}'||c==']')--depth;}}
 cJSON* root=cJSON_ParseWithOpts(text.c_str(),nullptr,true);
 if(!root||!cJSON_IsObject(root)||!cleanTree(root)){if(root)cJSON_Delete(root);error="JSON格式错误、重复字段或层次非法";return nullptr;}return root;
}
inline bool keys(cJSON* o,const char* const* allowed,unsigned count){for(cJSON* n=o->child;n;n=n->next){bool found=false;for(unsigned i=0;i<count;++i)if(!strcmp(n->string,allowed[i]))found=true;if(!found)return false;}return true;}
inline bool scoreJson(const String& text,Score& score,const char*& error){
 cJSON* root=parse(text,16384,error);if(!root)return false;
 const char* const allowed[]={"schema","title","bpm","tempo_bpm","events","total_quarters","total_beats"};
 bool ok=keys(root,allowed,7);int bpm=120,total=0;
 cJSON* schema=item(root,"schema");bool chords=cJSON_IsString(schema)&&!strcmp(schema->valuestring,"tang20k.score/2");
 if(schema&&(!cJSON_IsString(schema)||(!chords&&strcmp(schema->valuestring,"tang20k.score/1"))))ok=false;
 cJSON* bp=item(root,"bpm");if(!bp)bp=item(root,"tempo_bpm");
 if(item(root,"bpm")&&item(root,"tempo_bpm"))ok=false;
 if(bp&&!integer(bp,30,240,bpm))ok=false;
 cJSON* arr=item(root,"events");int n=cJSON_GetArraySize(arr);
 if(!cJSON_IsArray(arr)||n<1||n>63)ok=false;
 score=Score();score.bpm=uint16_t(bpm);
 if(ok)for(int i=0;i<n;++i){cJSON* e=cJSON_GetArrayItem(arr,i);const char* const ea[]={"note","pitch","start","duration","start_quarter","duration_quarters","velocity","pitches"};
  if(!cJSON_IsObject(e)||!keys(e,ea,8)){ok=false;break;}
  cJSON* note=item(e,"pitch");if(!note)note=item(e,"note");
  int p=0,v=0,st=0,du=0;uint8_t offsets[3]={};cJSON* pitches=item(e,"pitches");
  if(pitches){
   int count=cJSON_GetArraySize(pitches),last=0;
   if(!chords||note||!cJSON_IsArray(pitches)||count<1||count>4){ok=false;break;}
   for(int j=0;j<count;++j){int n=0;if(!integer(cJSON_GetArrayItem(pitches,j),41,72,n)||(j&&n<=last)){ok=false;break;}if(j==0)p=n;else offsets[j-1]=uint8_t(n-p);last=n;}
   if(!ok)break;
  }else if(!integer(note,0,127,p)||(item(e,"pitch")&&item(e,"note"))){ok=false;break;}
  if(!integer(item(e,"velocity"),1,127,v)){ok=false;break;}
  if(item(e,"start_quarter")||item(e,"duration_quarters")){
   if(item(e,"start")||item(e,"duration")||!integer(item(e,"start_quarter"),0,243,st)||!integer(item(e,"duration_quarters"),1,244,du)){ok=false;break;}
  }else{cJSON* a=item(e,"start");cJSON* b=item(e,"duration");
   if(!cJSON_IsNumber(a)||!cJSON_IsNumber(b)){ok=false;break;}
   cJSON x=*a,y=*b;x.valuedouble*=4;y.valuedouble*=4;
   if(!integer(&x,0,243,st)||!integer(&y,1,244,du)){ok=false;break;}
  }
  score.events[i]={uint8_t(p),uint8_t(v),uint16_t(st),uint16_t(du),{0,0,0}};memcpy(score.events[i].offsets,offsets,3);score.count=uint8_t(i+1);
 }
 if(item(root,"total_quarters")&&item(root,"total_beats"))ok=false;
 if(item(root,"total_quarters")&&!integer(item(root,"total_quarters"),1,244,total))ok=false;
 if(item(root,"total_beats")){cJSON t=*item(root,"total_beats");if(!cJSON_IsNumber(&t))ok=false;else{t.valuedouble*=4;if(!integer(&t,1,244,total))ok=false;}}
 score.melodyQuarters=uint16_t(total);if(!ok)error="曲谱字段/音高/时值非法；start与duration以拍为单位，须1/4拍网格";
 if(ok)ok=score.build(error);cJSON_Delete(root);return ok;
}
inline bool mapJson(const String& text,Mapping& map,bool& panic,const char*& error,bool* disabled=nullptr){
 cJSON* root=parse(text,4096,error);if(!root)return false;
 const char* const allowed[]={"schema","notes","pads","cc","panic_before_commit","disabled"};bool ok=keys(root,allowed,6);
 uint8_t* targets[]={map.notes,map.pads,map.cc};const char* names[]={"notes","pads","cc"};unsigned sizes[]={128,4,4};
 for(unsigned k=0;k<3&&ok;++k){cJSON* a=item(root,names[k]);if(!cJSON_IsArray(a)||cJSON_GetArraySize(a)!=int(sizes[k])){ok=false;break;}
  for(unsigned i=0;i<sizes[k];++i){int x=0;if(!integer(cJSON_GetArrayItem(a,i),0,127,x)){ok=false;break;}targets[k][i]=uint8_t(x);}}
 cJSON* p=item(root,"panic_before_commit");panic=cJSON_IsTrue(p);if(p&&!cJSON_IsBool(p))ok=false;
 cJSON* dis=item(root,"disabled");if(dis&&!cJSON_IsBool(dis))ok=false;if(disabled)*disabled=cJSON_IsTrue(dis);
 if(!ok)error="映射须完整包含notes[128]、pads[4]、cc[4]及0..127整数";
 if(ok)ok=map.validate(error);cJSON_Delete(root);return ok;
}
inline String mappingJson(const Mapping& m,bool disabled=false){String s=String("{\"schema\":\"tang20k.mapping/1\",\"disabled\":")+(disabled?"true":"false")+",\"notes\":[";for(unsigned i=0;i<128;++i){if(i)s+=',';s+=String(m.notes[i]);}s+="],\"pads\":[";for(unsigned i=0;i<4;++i){if(i)s+=',';s+=String(m.pads[i]);}s+="],\"cc\":[";for(unsigned i=0;i<4;++i){if(i)s+=',';s+=String(m.cc[i]);}s+="]}";return s;}
} // namespace v041
