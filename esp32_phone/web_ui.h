#pragma once
#include <pgmspace.h>
static const char PHONE_HTML[] PROGMEM = R"PHONEHTML(<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark"><title>Tang20K 乐器控制</title>
<style>
:root{font:16px/1.55 system-ui,-apple-system,"Microsoft YaHei",sans-serif;color:#edf1fb;background:#10151f}*{box-sizing:border-box}body{margin:0}main{max-width:860px;margin:auto;padding:22px 16px 60px}h1{font-size:27px;margin:0 0 4px}h2{font-size:19px;margin:0 0 16px}p{margin:8px 0;color:#b9c7db}header{margin-bottom:20px}.badge{display:inline-block;padding:4px 12px;border-radius:20px;background:#4c3629;color:#ffcc96;margin:12px 0 4px}.badge.good{background:#153f39;color:#9eedd1}.card{background:#1b2432;border:1px solid #344056;border-radius:16px;padding:20px;margin:14px 0}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px 24px}.control{min-width:0}.control label{display:block;font-weight:600}.actual{display:block;color:#9aacc4;font-size:13px;min-height:22px}.draft{float:right;color:#9ee4db}select,input[type=range]{width:100%;min-height:44px;margin:6px 0}select{background:#111b29;color:inherit;border:1px solid #59718f;border-radius:8px;padding:8px}input{accent-color:#70d9c3}button,.file{font:inherit;display:inline-block;background:#244c50;color:#e8ffff;border:1px solid #5f9c9b;border-radius:9px;min-height:44px;padding:9px 16px;cursor:pointer}button:disabled,input:disabled,select:disabled,.disabled{opacity:.45;cursor:not-allowed}.actions{display:flex;gap:10px;flex-wrap:wrap}.panic{background:#602b36;border-color:#e58b96;width:100%;font-weight:700}.small{font-size:13px}#notice{padding:12px;border-radius:10px;min-height:48px;background:#243247;color:#d9e8fb;overflow-wrap:anywhere}#notice.error{background:#4b2631;color:#ffc2c9}#flags{white-space:pre-line}#file{display:none}summary{cursor:pointer;color:#b8d9ef}footer{color:#8ba0b9;font-size:13px}a{color:#9ee4db}@media(max-width:520px){.grid{grid-template-columns:1fr}.card{padding:16px}main{padding:16px 12px 40px}}
.live-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.live-grid>div{min-width:0}progress{width:100%;height:18px;accent-color:#70d9c3}.live-value{white-space:pre-line;overflow-wrap:anywhere}.live-warning{color:#ffcc96}#live-status{white-space:pre-line}#live-fsr[data-stale=true]{opacity:.6}@media(max-width:520px){.live-grid{grid-template-columns:1fr}}
</style></head><body><main>
<header><h1>Tang20K 乐器控制</h1><p><a href="/extensions">曲谱上传 · Note/Pad/CC 映射 · 实际PCM录音</a></p><p>手机参数面板 · 声音由 FPGA 乐器输出</p>
<div id="link" class="badge" role="status">正在连接 ESP32，FPGA 状态未知</div>
<div id="telemetry" class="small"></div></header>
<div id="notice" role="status" aria-live="polite">等待完整回读。调整后以 FPGA 实际确认为准。</div>
  <section class="card" id="live-panel"><h2>实时诊断 · 只读</h2>
  <p id="live-status" role="status" aria-live="polite">等待遥测能力探测；参数控制可独立使用。</p>
  <div class="live-grid" id="live-fsr" data-stale="true">
    <div><strong>FSR0 · 明亮度</strong><p class="live-value" id="fsr0-value">RAW — · LVL — · CAL —</p><progress id="fsr0-bar" max="255" value="0" aria-label="FSR0 表情量"></progress></div>
    <div><strong>FSR1 · 拨弦阻尼</strong><p class="live-value" id="fsr1-value">RAW — · LVL — · CAL —</p><progress id="fsr1-bar" max="255" value="0" aria-label="FSR1 表情量"></progress></div>
  </div>
  <p class="live-value live-warning" id="live-adc">ADC 状态未知</p>
  <p class="live-value" id="live-midi">VEL — · BEND — · MOD —</p>
  <p class="live-value" id="live-beams">光电状态未知</p>
  <p class="live-value" id="live-voices">声部与测试状态未知</p>
  <p class="small">RAW 为十六进制 ADC 原码，LVL 为 0–255 表情量，CAL 为校准状态；不是 kg 或电压。此区只读，不写入参数预设。</p></section>
<section class="card"><h2>演奏</h2><div id="play" class="grid"></div>
<p class="small">KEY：琴键直接发声，关闭光电扫弦。STRUM：按住琴键选择和弦，由光电触发扫弦，琴键本身不直接发声。HYBRID 混合：琴键立即发声，光电可独立扫出当前按住的和弦。切换结果以 FPGA 实际回读为准。</p></section>
<section class="card"><h2>效果器</h2><div id="fx" class="grid"></div>
<p class="small">实体旋钮：K1/CC93 延迟强度，K2/CC91 合唱强度，K3/CC71 混响强度，K4/CC74 总音量。每种效果保存自己的强度，转到该目标附近再继续转动，数值改变后切换到该效果；一次只开一种，强度 0 为干声。手机可单独设置模式、湿度、时间、反馈和调制。切模式恢复该效果的已存强度；改湿度后对应旋钮须重新软接管。OFF 下湿度属于最近选择的效果，复位后为延迟。</p></section>
<section class="card"><h2>ADSR 包络</h2><div id="env" class="grid"></div><p class="small">参数为 FPGA 的 0–255 原始整数刻度，未换算为毫秒。</p></section>
<section class="card"><h2>显示与输出</h2><div id="display" class="grid"></div>
<p class="small">digital zero 回读实际静音状态。FTDI 等其他控制源仍要求静音时，手机设为 0 可能仍回读 1，面板会报告未达到目标。HDMI 页码为协议的 0–3。</p></section>
<section class="card"><h2>JSON 参数预设</h2><div class="actions"><button id="export" disabled>导出最近回读值</button><button id="import" disabled>导入 JSON 预设</button><input id="file" type="file" accept="application/json,.json"></div>
<p class="small">仅参数通信与 JSON 导入导出。导入先校验整份文件；未知/重复字段、非整数或越界值整份拒绝。通过后依次 SET，硬件执行并非多参数原子事务；中途断链会停止剩余写入并重新回读。</p></section>
<section class="card"><h2>紧急停音</h2><button id="panic" class="panic" disabled>Panic · 清除持续音</button><p class="small">会取消尚未发出的参数写入；等待当前 UART 请求结束后优先发送。只有收到 FPGA 正常 ACK 才显示确认。</p></section>
<section class="card"><details><summary>硬件状态 / 演奏提示</summary><p id="flags">等待 FPGA 状态</p>
<p>Pad 使用打击乐通道 10。默认有 36 / 37 / 38 / 39 及既有 GM 别名；“曲谱、映射、录音”扩展页可配置四个 Pad 音符和 CC 映射。</p>
<p>主音量可由 K4 / MIDI CC7 改变，面板持续回读实际值。扩展页可录制 FPGA 的实际数字 PCM 并下载 WAV；不是手机麦克风录音，也不是模拟线路采样。</p>
  <p>接线：ESP32 GPIO17 TX → FPGA L9；FPGA N8 TX → ESP32 GPIO16 RX；两端共 GND。ESP32 自己用 USB 供电，两端 3V3 输出不要相连。</p></details></section>
<footer>AP：Tang20K-Music · 地址 http://192.168.4.1 · 仅本地网络控制</footer>
</main><script>
'use strict';
const specs=[
 ['volume','主音量',255,'play'],['timbre','音色',1,'play',['长笛 Flute','拨弦 Pluck']],
 ['input_mode','演奏模式',2,'play',['KEY 键盘','STRUM 扫弦','HYBRID 混合（键盘＋扫弦）']],
 ['fx_mode','FX 模式',3,'fx',['OFF 关闭','Delay 延迟','Chorus 合唱','Reverb 混响']],
 ['fx_wet','湿度 Wet',255,'fx'],['fx_time','时间 Time',255,'fx'],
 ['fx_feedback','反馈 Feedback',255,'fx'],['fx_modulation','调制 Modulation',255,'fx'],
 ['attack','Attack 起音',255,'env'],['decay','Decay 衰减',255,'env'],
 ['sustain','Sustain 持续',255,'env'],['release','Release 释音',255,'env'],
 ['hdmi_page','HDMI 页码',3,'display',['第 0 页','第 1 页','第 2 页','第 3 页']],
 ['filter','滤波器',1,'display',['关闭','开启']],['digital_zero','数字静音',1,'display',['关闭 / 正常输出','开启 / 数字归零']]
];
const limits=Object.fromEntries(specs.map(s=>[s[0],s[2]]));
const controls=new Map(), pending=new Map(), draft=new Map();
let ready=false,sending=false,panicQueued=false,panicRevision=0,token=0,state=null,boot=null,failureLatched=false;
let lastStateAt=0,pumpTimer=0,polling=false;
const $=id=>document.getElementById(id);
let liveSample=null,liveReceivedAt=0,liveConnected=false;
function clearLive(message){
 $('live-status').textContent=message;$('live-fsr').dataset.stale='true';
 for(let i=0;i<2;i++){$('fsr'+i+'-value').textContent='RAW — · LVL — · CAL —';$('fsr'+i+'-bar').value=0;}
 $('live-adc').textContent='ADC 状态未知';$('live-midi').textContent='VEL — · BEND — · MOD —';
 $('live-beams').textContent='光电状态未知';$('live-voices').textContent='声部与测试状态未知';
}
function paintLive(){
 const t=liveSample;
 if(!liveConnected){clearLive('链路未就绪，遥测未知；旧值已清除。');return;}
 if(!t){clearLive('当前 FPGA/桥接未提供遥测；参数控制可继续使用。');return;}
 if(t.status==='unsupported'){clearLive('当前 FPGA 不支持遥测；参数控制可继续使用。');return;}
 if(t.status==='unavailable'){clearLive('遥测能力探测或读取失败；参数控制可继续使用。');return;}
 if(!t.enabled||t.status==='disabled'){clearLive('遥测未启用；参数控制可继续使用。');return;}
 if(t.status!=='supported'){clearLive('正在探测遥测能力；参数控制可继续使用。');return;}
 if(!t.valid||!t.snapshot_valid||!Number.isFinite(t.age_ms)){clearLive('等待完整、有效的 FPGA 遥测快照。');return;}
 const age=Math.max(0,t.age_ms)+Math.max(0,Date.now()-liveReceivedAt);
 if(t.stale||age>=1000){clearLive('遥测过期（'+Math.floor(age)+' ms），当前值未知；参数控制独立运行。');return;}
 const integer=(x,max)=>Number.isInteger(x)&&x>=0&&x<=max;
 if(!Array.isArray(t.fsr)||t.fsr.length!==2||!t.fsr.every(f=>integer(f.raw,65535)&&integer(f.level,255)&&typeof f.calibrated==='boolean')||
    !t.adc||!t.midi||!t.beams||!t.test||!integer(t.midi.velocity,127)||!integer(t.midi.modulation,127)||
    !Number.isInteger(t.midi.bend)||t.midi.bend< -256||t.midi.bend>255||!integer(t.voices,32)||!integer(t.test.requested,32)){
   clearLive('遥测格式不完整，当前值未知。');return;
 }
 $('live-status').textContent='快照 #'+t.snapshot_id+' · 采集起点距今 '+Math.floor(age)+' ms（只读）';
 $('live-fsr').dataset.stale=String(!!t.adc.stale||!!t.adc.fault);
 for(let i=0;i<2;i++){
   const f=t.fsr[i];$('fsr'+i+'-value').textContent='RAW 0x'+f.raw.toString(16).toUpperCase().padStart(4,'0')+' · LVL '+f.level+' · CAL '+(f.calibrated?'已校准':'未校准');
   $('fsr'+i+'-bar').value=f.level;
 }
 $('live-adc').textContent='ADC '+(t.adc.fault?'故障':'无故障')+' · '+(t.adc.stale?'采样已过期':'采样有效');
 $('live-midi').textContent='VEL '+t.midi.velocity+' · BEND '+t.midi.bend+' · MOD '+t.midi.modulation+'\nMIDI 帧错误：'+(t.midi.frame_error?'有':'无')+' · 溢出：'+(t.midi.overflow?'有':'无');
 const b=t.beams;
 $('live-beams').textContent='光电 '+(b.enabled?'已启用':'未启用')+' · '+(b.ready?'就绪':'未就绪')+' · '+(b.busy?'扫弦忙':'空闲')+'\nA 电平 '+Number(!!b.electrical_a)+' / '+(b.blocked_a?'遮挡':'未遮挡')+'；B 电平 '+Number(!!b.electrical_b)+' / '+(b.blocked_b?'遮挡':'未遮挡');
 $('live-voices').textContent='活动声部 '+t.voices+' / 32 · 测试请求 '+t.test.requested+'\n测试 '+(t.test.active?'活动':'未活动')+' · 巡检 '+(t.test.sweep?'运行':'停止')+' · 索引 '+t.test.index+' · overrun '+(t.test.overrun?'有':'无')+' · 测试所有权 '+(t.test.owned?'有':'无')+' · 测试音源 '+(t.test.mode?'开启':'关闭');
}
function notice(text,error=false){$('notice').textContent=text;$('notice').className=error?'error':'';}
function enable(){
 for(const c of controls.values()) c.input.disabled=!ready;
 $('panic').disabled=!ready||panicQueued||!!panicRevision;
 $('export').disabled=!ready||pending.size>0||sending||draft.size>0;
 $('import').disabled=!ready||pending.size>0||sending||draft.size>0;
}
for(const [key,title,max,group,choices] of specs){
 const box=document.createElement('div');box.className='control';
 const label=document.createElement('label');label.htmlFor=key;label.textContent=title;
 const wanted=document.createElement('span');wanted.className='draft';label.append(wanted);
 const input=document.createElement(choices?'select':'input');input.id=key;input.disabled=true;
 if(choices) choices.forEach((text,index)=>{const o=document.createElement('option');o.value=index;o.textContent=text;input.append(o);});
 else {input.type='range';input.min=0;input.max=max;input.step=1;}
 const actual=document.createElement('span');actual.className='actual';actual.textContent='FPGA 实际值：未知';
 box.append(label,input,actual);$(group).append(box);controls.set(key,{input,wanted,actual,title,seen:false,editing:false});
 input.addEventListener('input',()=>{controls.get(key).editing=true;wanted.textContent='拟设 '+input.value;});
 input.addEventListener('blur',()=>{controls.get(key).editing=false;});
 input.addEventListener('change',()=>{
  controls.get(key).editing=false;
  if(!ready) return;
  if(!pending.size)failureLatched=false;
  const value=Number(input.value),t=++token;
  draft.set(key,{value,token:t});pending.set(key,{value,token:t,revision:0});
  wanted.textContent='待发送 '+value;notice('待发送；尚未获得 FPGA 确认。');enable();
  clearTimeout(pumpTimer);pumpTimer=setTimeout(pump,100);
 });
}
function validatePreset(text){
 if(new TextEncoder().encode(text).length>1024) throw Error('预设最多 1024 字节');
 const obj=JSON.parse(text);
 if(!obj||typeof obj!=='object'||Array.isArray(obj)||!Object.keys(obj).length) throw Error('预设必须为非空参数对象');
 for(const [key,value] of Object.entries(obj)){
  if(!Object.hasOwn(limits,key)) throw Error('未知或只读字段：'+key);
  if(!Number.isInteger(value)||value<0||value>limits[key]) throw Error(key+' 必须为 0–'+limits[key]+' 的整数');
 }
 return obj;
}
async function api(url,body){
 const abort=new AbortController(),timer=setTimeout(()=>abort.abort(),1800);
 try{
  const response=await fetch(url,{method:body===undefined?'GET':'POST',cache:'no-store',signal:abort.signal,
    headers:body===undefined?{}:{'Content-Type':'application/json'},body});
  const data=await response.json();if(!response.ok) throw Error(data.error||('HTTP '+response.status));return data;
 }finally{clearTimeout(timer);}
}
function forgetWrites(reason){
 const had=pending.size||draft.size||panicRevision||panicQueued;
 draft.clear();pending.clear();panicQueued=false;panicRevision=0;clearTimeout(pumpTimer);
 for(const c of controls.values()){c.wanted.textContent='';c.editing=false;}
 if(had) notice(reason,true);
}
function offline(reason){ready=false;liveConnected=false;paintLive();forgetWrites(reason);$('link').textContent=reason+'；旧值已过期';$('link').className='badge';
 for(const c of controls.values()) if(c.seen)c.actual.textContent=c.actual.textContent.replace(/（过期）$/,'')+'（过期）';enable();}
async function transmit(raw,entries){
 sending=true;enable();
 try{
  const result=await api('/api/apply',raw);
  if(result.accepted!==true||!Number.isInteger(result.revision)) throw Error('桥接应答格式错误');
  // A stale/disconnected poll may have cleared these tokens while HTTP was pending.
  for(const [key,entry] of entries){const p=pending.get(key);if(p&&p.token===entry.token){p.revision=result.revision;controls.get(key).wanted.textContent='等待 ACK '+p.value;}}
  if(ready) notice('请求已入队，等待 FPGA 实际值 ACK。');
 }catch(error){offline('写请求未确认：'+error.message+'；恢复后请检查回读值');notice('写请求失败或应答不明，未显示成功；不会自动补发。'+error.message,true);}
 finally{sending=false;enable();if(ready)setTimeout(pump,0);}
}
async function pump(){
 if(sending||!ready)return;
 if(panicQueued){
  panicQueued=false;sending=true;enable();
  try{const r=await api('/api/panic','{}');if(r.accepted!==true||!Number.isInteger(r.revision))throw Error('桥接应答格式错误');
    if(ready){panicRevision=r.revision;notice('Panic 已入队，等待 FPGA ACK。');}}
  catch(error){offline('Panic 未确认');notice('Panic 未确认：'+error.message,true);}
  finally{sending=false;enable();if(ready)setTimeout(pump,0);}return;
 }
 if(!draft.size)return;
 const entries=new Map(draft);draft.clear();
 const obj=Object.fromEntries([...entries].map(([key,e])=>[key,e.value]));
 await transmit(JSON.stringify(obj),entries);
}
const errorText={1:'不支持的命令',2:'未知/只读参数',3:'值越界',4:'协议版本/保留位错误',10:'FPGA 链路超时',11:'已被 Panic 取消',12:'未达到目标 / 控制冲突'};
function render(s){
 if(boot!==null&&boot!==s.boot_id)forgetWrites('ESP32 已重启，旧请求确认已失效；正在重新回读。');
 boot=s.boot_id;state=s;lastStateAt=Date.now();
 const wasReady=ready;ready=s.linked&&s.synced&&!s.stale&&specs.every(([key])=>s.params[key]?.valid);
 if(!ready){offline(s.linked?'UART 已响应，正在完整回读':'FPGA UART 断链');}
 else{
  $('link').textContent='FPGA 已连接 · 实际值持续回读';$('link').className='badge good';
  if(!wasReady)notice('完整回读完成，可以调整参数。旧的待发写入不会补发。');
 }
 $('telemetry').textContent='ACK '+(s.ack_age_ms??'—')+' ms · 队列 '+s.queued+' · TX/RX '+s.tx+'/'+s.rx+' · 重试 '+s.retries;
 let confirmed=0,failed=false;
 for(const [key,c] of controls){
  const p=s.params[key];if(!p)continue;
  if(p.valid)c.seen=true;
  c.actual.textContent=c.seen?'FPGA 实际值：'+p.value+(!ready||!p.valid?'（过期）':''):'FPGA 实际值：未知';
  const waiting=pending.get(key);
  if(ready&&waiting?.revision){
   if(p.failed===waiting.revision){notice(c.title+' 设置失败：'+(errorText[p.error]||p.error)+'；目标 '+waiting.value+'，实际 '+p.value,true);c.wanted.textContent=p.error===12?'未达到目标':'失败';pending.delete(key);failed=true;failureLatched=true;}
   else if(p.applied===waiting.revision){
    pending.delete(key);
    if(p.value!==waiting.value){notice(c.title+' 回读未达到目标 / 控制冲突；目标 '+waiting.value+'，实际 '+p.value,true);c.wanted.textContent='未达到目标';failed=true;failureLatched=true;}
    else {c.wanted.textContent='';++confirmed;}
   }
   else if(p.requested>waiting.revision){notice(c.title+' 的请求已被较新请求替代，当前显示实际回读值。');c.wanted.textContent='';pending.delete(key);}
  }
  if(ready&&!pending.has(key)&&!c.editing){c.input.value=p.value;if(!['失败','未达到目标'].includes(c.wanted.textContent))c.wanted.textContent='';}
 }
 if(confirmed&&!failed&&!failureLatched&&!pending.size)notice('FPGA 已确认；面板显示实际回读值。');
 if(panicRevision&&ready){
  if(s.panic.failed===panicRevision){notice('Panic 失败：'+(errorText[s.panic.error]||s.panic.error),true);panicRevision=0;}
  else if(s.panic.applied===panicRevision){notice('FPGA 已确认 Panic。');panicRevision=0;}
  else if(s.panic.requested>panicRevision){notice('Panic 已被新的请求替代。');panicRevision=0;}
 }
 const f=s.params.status_flags;
 if(f?.valid){const b=f.value;$('flags').textContent='Flags 0x'+b.toString(16).padStart(2,'0')+(ready?'':'（过期）')+'\n'+[
  'MIDI 已见/按住：'+!!(b&1),'ADS 故障：'+!!(b&2),'触摸故障：'+!!(b&4),'光学就绪：'+!!(b&8),
  '光电输入已启用（STRUM / HYBRID，bit4）：'+!!(b&16),'MIDI 溢出：'+!!(b&32),'数字归零：'+!!(b&64)].join('\n');}
 else $('flags').textContent='状态过期，等待 FPGA 回读';
 liveSample=s.telemetry??null;liveReceivedAt=Date.now();liveConnected=!!ready;paintLive();
 enable();
}
async function poll(){
 if(polling)return;polling=true;
 try{render(await api('/api/state'));}catch(error){offline('手机无法取得 ESP32 状态');}
 finally{polling=false;setTimeout(poll,350);}
}
$('panic').addEventListener('click',()=>{if(!ready)return;failureLatched=false;forgetWrites('Panic 将取消待发参数写入。');panicQueued=true;notice('正在请求 Panic；等待 FPGA 确认。');enable();pump();});
$('export').addEventListener('click',()=>{
 if(!ready||!state||pending.size)return;
 const obj=Object.fromEntries(specs.map(([key])=>[key,state.params[key].value]));
 const url=URL.createObjectURL(new Blob([JSON.stringify(obj,null,2)+'\n'],{type:'application/json'}));
 const a=document.createElement('a');a.href=url;a.download='Tang20K-preset.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
});
$('import').addEventListener('click',()=>{if(ready)$('file').click();});
$('file').addEventListener('change',async()=>{
 const file=$('file').files[0];$('file').value='';if(!file)return;
 if(file.size>1024){notice('预设最多 1024 字节，未应用。',true);return;}
 try{
  const raw=await file.text(),obj=validatePreset(raw);
  if(!ready||sending||pending.size||draft.size)throw Error('请等待链路就绪和当前参数确认');
  failureLatched=false;const entries=new Map();for(const [key,value] of Object.entries(obj)){const e={value,token:++token,revision:0};entries.set(key,e);pending.set(key,e);}
  notice('预设已通过本地校验，等待桥接严格校验与 FPGA 逐项 ACK。');await transmit(raw,entries);
 }catch(error){notice('预设未应用：'+error.message,true);}
});
setInterval(()=>{if(ready&&Date.now()-lastStateAt>1800)offline('手机状态心跳超时');},300);
setInterval(paintLive,100); // local freshness also expires between HTTP replies
poll();
</script></body></html>)PHONEHTML";
