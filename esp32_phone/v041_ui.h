#pragma once
#include <pgmspace.h>
static const char V041_HTML[] PROGMEM=R"V041HTML(<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>V047 手机演奏 · 曲谱 · PCM录音</title><style>
:root{font:16px/1.6 system-ui,"Microsoft YaHei",sans-serif;color:#edf1fb;background:#10151f}*{box-sizing:border-box}body{max-width:960px;margin:auto;padding:20px}h1{font-size:26px}h2{font-size:21px}a{color:#91e5d1}section{background:#1b2432;border:1px solid #344056;border-radius:14px;padding:20px;margin:18px 0}button,input,textarea{font:inherit}button{background:#245758;color:#fff;border:1px solid #73a7a2;border-radius:8px;padding:10px 14px;margin:5px 8px 5px 0;cursor:pointer}button:disabled{opacity:.4}textarea,input[type=url]{width:100%;color:#eef3fa;background:#101925;border:1px solid #63758d;border-radius:6px;padding:10px}textarea{height:210px;font:14px/1.5 Consolas,monospace}input[type=number]{background:#101925;color:#fff;border:1px solid #63758d;border-radius:4px;width:78px;padding:6px}.small{font-size:13px;color:#b9c7db}.notice{background:#253b48;border-radius:8px;padding:12px;white-space:pre-wrap;overflow-wrap:anywhere}.error{background:#542938;color:#ffd1da}.map-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:8px;max-height:360px;overflow:auto}.map-grid label{display:flex;justify-content:space-between;align-items:center;font-size:13px}progress,audio{width:100%}details{margin:12px 0}label{display:inline-block}#job{position:sticky;top:5px;z-index:2}summary{cursor:pointer}input[type=file]{max-width:100%}</style>
<style>select{font:inherit;background:#101925;color:#eef3fa;border:1px solid #63758d;border-radius:6px;padding:8px;max-width:100%}</style>
<h1>手机演奏 · 曲谱 · 实际PCM录音</h1><p><a href="/">返回原参数 / FX / ADSR / 遥测面板</a></p>
<p class="small">手机通过本地 Wi-Fi 控制。声音合成、曲谱指引和 HDMI 均继续由 FPGA 处理；不使用手机麦克风。</p>
<div class="notice" id="job" role="status">正在读取状态</div><progress id="progress" max="1" value="0"></progress>
<section><h2>手机演奏 · 三种模式</h2>
<p><label>请求模式 <select id="guide-mode" aria-label="请求演奏模式"><option value="0">固定BPM检验</option><option value="1">自动演奏</option><option value="2">逐音练习</option></select></label> <button id="guide-mode-submit">设置模式</button></p>
<p><label>请求曲目 <select id="guide-song" aria-label="请求曲目"><option value="0">小星星 · 120 BPM</option><option value="1">灯阶练习曲 · 112 BPM</option><option value="2">溪桥练习曲 · 100 BPM</option><option value="3">自定义 · 上传曲谱BPM</option></select></label></p>
<p><button data-guide-action="0">选择并暂停</button><button data-guide-action="1">开始</button><button data-guide-action="2">暂停 / 继续</button><button data-guide-action="3">重播</button><button id="guide-refresh">刷新实际状态</button></p>
<p class="small">固定BPM检验按曲谱节奏演奏；自动演奏由FPGA发声；逐音练习等待目标音组：每个音都须重新按下并同时保持，依次点过不算和弦完成。下拉框是待发送的请求，实际模式、曲目与进度以下方FPGA读回为准。设置ACK仅代表请求已接受。录音期间暂停导奏刷新与设置。</p>
<div id="guide-state" class="notice" role="status" aria-live="polite">尚未读回FPGA导奏状态</div><p id="guide-request" class="small" role="status"></p></section>
<section><h2>自定义曲谱 · 最多四音和弦</h2><p>任意符合格式的曲谱均可上传，最多63组音符，音高F2–C5（MIDI 41–72），1/4拍网格，BPM 30–240。旋律最多61拍，另有固定两拍预备。V047 支持 pitches 数组，每组1–4个升序且不重复的音，共用起止；不同组不能重叠。旧单音JSON继续支持。start/duration 是拍；也支持 start_quarter/duration_quarters 整数格式。</p>
<textarea id="score" aria-label="曲谱JSON">{"schema":"tang20k.score/1","title":"我的练习","bpm":120,"events":[{"pitch":60,"start":0,"duration":1,"velocity":96},{"pitch":64,"start":1,"duration":1,"velocity":80}]}</textarea>
<p><input id="score-file" type="file" accept=".json,application/json" aria-label="导入曲谱文件"></p>
<button id="score-upload">保存并上传 FPGA</button><button id="score-list">查看已上传曲库</button><a href="/api/scores/download">下载已保存曲谱 JSON</a>
<p><button data-guide="0">选择自定义并暂停</button><button data-guide="1">开始自定义</button><button data-guide="2">自定义暂停 / 继续</button><button data-guide="3">重播自定义</button></p>
<p class="small">上传提交后选择自定义并暂停；是否自动发声由演奏模式决定。上方演奏区可控制全部三首预置曲和自定义曲；此处四键保留旧自定义控制接口。</p>
<details><summary>从在线 URL 读取曲谱</summary><input id="score-url" type="url" placeholder="https://可访问并允许CORS的服务器/score.json"><button id="score-fetch">读取 URL 到编辑框</button><p class="small">需要手机当前网络实际能上网，且服务器允许 CORS。Tang20K 热点自身不提供互联网；失败时请联网下载 JSON 后，通过上面的文件导入。URL读取只填编辑框，仍须点击上传。</p></details><div id="library" class="small"></div></section>
<section><h2>运行时 Note / 四Pad / 四CC映射</h2><p class="small">旋律128项必须是0–127的单射，避免两物理键映到同音而提前松音。Pad为通道10；四个来源可编辑，动作固定。CC来源可编辑，目标固定为四旋钮功能。映射提交须FPGA空闲，或在明确Panic确认后提交。映射仅改变旋律发声音高；按住显示与光电和弦选择保留raw原语义。恢复默认使用MAP_DISABLE，保留全部V040 GM别名。</p>
<button id="map-load">读取已保存 / 当前映射</button><button id="map-identity">编辑框恢复默认</button><details><summary>编辑128个旋律 Note</summary><div id="notes" class="map-grid"></div></details>
<div id="pads" class="map-grid"></div><p></p><div id="cc" class="map-grid"></div>
<p><label><input id="map-panic" type="checkbox">提交前发送并等待 FPGA Panic 确认（会停音）</label></p>
<button id="map-submit">提交完整映射并保存</button><button id="map-default">提交 FPGA 默认映射</button><button id="map-export">导出映射 JSON</button><input id="map-file" type="file" accept=".json,application/json" aria-label="导入映射文件"><p id="map-state" class="small"></p></section>
<section><h2>真实最终PCM录音</h2><p>最终音频每6采样平均：<strong>15625 Hz · 16bit · mono</strong>，最长30秒。包括实际演奏、FX、音量和静音，不是MIDI事件录制。仅保留一段，开始会替换上一段。</p>
<label>秒数 <input id="seconds" type="number" min="1" max="30" value="30"></label><button id="rec-start">开始实际PCM录音</button><button id="rec-stop">停止并排空</button>
<div id="rec-state" class="notice">等待状态</div><audio id="player" controls preload="none"></audio><button id="rec-play">播放校验通过的 WAV</button><a id="wav-download" href="/api/recordings/last.wav" download>下载实际 WAV</a>
<p class="small">EOF的真实样本数用于去除最后一帧填充；SEQ、drops、字节数和FPGA CRC全部通过才显示完成。空间不足会报告可录上限。Flash写停顿、UART/RAM溢出均属于未通过。</p>
<details><summary>存储初始化</summary><p class="small">仅当LittleFS未挂载时使用。初始化会清空该分区中的曲谱、映射和录音，不修改FPGA固件。</p><button id="format">明确初始化 LittleFS</button></details></section>
<script>
'use strict';
// These validators are executed directly by the offline Node suite.
const V041=(()=>{
 const int=(x,a,b)=>Number.isInteger(x)&&x>=a&&x<=b;
 function score(o){
  if(!o||Array.isArray(o)||typeof o!=='object')throw Error('曲谱须JSON对象');
  const allowed=['schema','title','bpm','tempo_bpm','events','total_quarters','total_beats'];if(Object.keys(o).some(k=>!allowed.includes(k)))throw Error('未知曲谱字段');
  if(o.schema!==undefined&&!['tang20k.score/1','tang20k.score/2'].includes(o.schema))throw Error('未知曲谱schema');
  const bpm=o.bpm??o.tempo_bpm??120;if(o.bpm!==undefined&&o.tempo_bpm!==undefined)throw Error('BPM字段重复');
  if(!int(bpm,30,240)||!Array.isArray(o.events)||o.events.length<1||o.events.length>63)throw Error('BPM须30..240，事件须1..63');
  let end=0;const events=o.events.map(e=>{
   if(!e||Array.isArray(e)||typeof e!=='object'||Object.keys(e).some(k=>!['pitch','note','start','duration','start_quarter','duration_quarters','velocity','pitches'].includes(k)))throw Error('音符字段错误');
   if(e.pitch!==undefined&&e.note!==undefined)throw Error('note与pitch不能并列');const pitches=e.pitches;
   if(pitches!==undefined&&(o.schema!=='tang20k.score/2'||e.pitch!==undefined||e.note!==undefined||!Array.isArray(pitches)||pitches.length<1||pitches.length>4||pitches.some((p,i)=>!int(p,41,72)||(i>0&&p<=pitches[i-1]))))throw Error('pitches须1..4个升序唯一音高41..72，且schema为score/2');
   const pitch=pitches===undefined?(e.pitch??e.note):pitches[0];
   const offsets=pitches===undefined?[]:pitches.slice(1).map(p=>p-pitch);
   const quarters=e.start_quarter!==undefined||e.duration_quarters!==undefined;
   if(quarters&&(e.start!==undefined||e.duration!==undefined))throw Error('不能混用拍和quarter字段');
   const start=quarters?e.start_quarter:e.start*4,duration=quarters?e.duration_quarters:e.duration*4;
   if(!int(pitch,41,72)||!int(e.velocity,1,127)||!int(start,0,243)||!int(duration,1,244)||start<end||start+duration>244)throw Error('音高须41..72、1/4拍网格、音组不重叠、旋律不超过61拍');
   end=start+duration;return {pitch,start,duration,velocity:e.velocity,offsets};
  });
  if(o.total_quarters!==undefined&&o.total_beats!==undefined)throw Error('总时值字段重复');const length=o.total_quarters??(o.total_beats===undefined?end:o.total_beats*4);
  if(!int(length,1,244)||length<end)throw Error('总时值不足或过长');
  const total=length+8,words=[];let sum=0;
  for(let q=0;q<total;q++){
   const current=events.findIndex(e=>q>=e.start+8&&q<e.start+8+e.duration);let next=events.findIndex(e=>e.start+8>q),w=0;
   if(current>=0){const e=events[current];w=e.pitch|(current<<7)|(1<<13)|(q===e.start+8?1<<14:0)|(e.duration>4?1<<15:0)|(e.velocity<<24);next=current+1<events.length?current+1:-1;if(e.offsets.length)w=(w&65535)|0x80000000|((e.offsets[0]||0)<<16)|((e.offsets[1]||0)<<21)|((e.offsets[2]||0)<<26);}
   if(next>=0&&!(w&0x80000000))w|=(events[next].pitch<<16)|(1<<23);w>>>=0;words.push(w);for(let b=0;b<4;b++)sum=(sum+((w>>>(8*b))&255))&65535;
  }
  return {bpm,total,events,words,sum,samples_per_beat:Math.round(5625000/bpm)};
 }
 function defaults(){return {schema:'tang20k.mapping/1',disabled:true,notes:Array.from({length:128},(_,i)=>i),pads:[36,38,37,39],cc:[93,91,71,74]};}
 function mapping(o){
  if(!o||Object.keys(o).some(k=>!['schema','notes','pads','cc','panic_before_commit','disabled'].includes(k)))throw Error('未知映射字段');
  for(const [k,n] of [['notes',128],['pads',4],['cc',4]])if(!Array.isArray(o[k])||o[k].length!==n||o[k].some(v=>!int(v,0,127))||new Set(o[k]).size!==n)throw Error(k+'须完整、整数且来源/目标唯一');
  if(o.cc.some(c=>[1,7,64,120,121,123].includes(c)))throw Error('不能占用保护CC');if(o.disabled!==undefined&&typeof o.disabled!=='boolean')throw Error('disabled须布尔');if(o.panic_before_commit!==undefined&&typeof o.panic_before_commit!=='boolean')throw Error('Panic字段须布尔');return o;
 }
 const guideModes=['固定BPM检验','自动演奏','逐音练习'],guideSongs=['小星星 · 120 BPM','灯阶练习曲 · 112 BPM','溪桥练习曲 · 100 BPM','自定义'];
 function guideView(s){
  const valid=s&&int(s.mode,0,2)&&int(s.roll_song,0,3)&&int(s.selected_song,0,3)&&int(s.step,0,63)&&int(s.expected_note,0,127)&&['active','done','practice_hold','external_suspend','expected_valid','fresh','verified'].every(k=>typeof s[k]==='boolean');
  if(!valid)return {fresh:false,bad:true,text:'尚无可验证的FPGA导奏状态'+(s?.error?'：'+s.error:'')};
  const fresh=s.fresh&&s.verified&&int(s.age_ms,0,3000)&&s.ttl_ms===3000;
  const flags=[s.active?'运行':'暂停',s.done?'已完成':'',s.practice_hold?'等待目标音':'',s.external_suspend?'外部暂停':''].filter(Boolean).join(' · ');
  return {fresh,bad:!fresh,text:(fresh?'FPGA实际状态 · 已读回':'缓存已过期或尚未验证 · 不能视为当前状态')+'\n模式：'+guideModes[s.mode]+'\n已选曲目：'+guideSongs[s.selected_song]+'\n滚动曲目：'+guideSongs[s.roll_song]+'\n'+flags+' · step '+s.step+' · 目标音 '+(s.expected_valid?s.expected_note:'无')+'\n距读回 '+s.age_ms+' ms'+(s.error?'\n'+s.error:'')+(s.pending?'\n请求处理中，等待读回':'')};
 }
 return {score,mapping,defaults,guideView};
})();
const $=id=>document.getElementById(id);let currentJob=0,lastWav=false,mappingDisabled=true;
function notice(s,bad=false){$('job').textContent=s;$('job').className='notice'+(bad?' error':'');}
async function api(path,method='GET',body){const c=new AbortController(),t=setTimeout(()=>c.abort(),8000);try{const r=await fetch(path,{method,cache:'no-store',signal:c.signal,headers:body===undefined?{}:{'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});const o=await r.json();if(!r.ok)throw Error(o.error||('HTTP '+r.status));return o;}finally{clearTimeout(t);}}
async function job(path,body,method='POST'){try{const j=await api(path,method,body);currentJob=j.id;notice('作业 '+j.id+' 已入队，等待 FPGA 确认');$('progress').value=0;}catch(e){notice(e.message,true);}}
let guideCache=null,guideRefreshJob=0,guideControlJob=0,guideBusy=false,guideReading=false,guideReceivedAt=0;
function paintGuide(s){guideCache=s;guideReceivedAt=Date.now();const v=V041.guideView(s);$('guide-state').textContent=v.text;$('guide-state').className='notice'+(v.bad?' error':'');}
function invalidateGuide(reason){if(guideCache)paintGuide({...guideCache,fresh:false,verified:false,error:reason});else{$('guide-state').textContent=reason;$('guide-state').className='notice error';}}
async function guideCommand(path,body){
 if(guideBusy)return;guideBusy=true;
 try{const j=await api(path,'POST',body);currentJob=guideControlJob=j.id;invalidateGuide('请求已入队，尚未读回实际结果');$('guide-request').textContent='作业 '+j.id+' 已入队，ACK只代表接受；等待op22实际状态';notice('导奏请求已入队，等待实际状态读回');}
 catch(e){$('guide-request').textContent='请求失败：'+e.message;notice(e.message,true);}finally{guideBusy=false;}
}
async function refreshGuide(manual=false){
 if(guideBusy||guideRefreshJob||currentJob){if(manual)$('guide-request').textContent='有作业进行中，完成后再刷新';return;}
 guideBusy=true;try{const j=await api('/api/guide/state','POST',{});guideRefreshJob=j.id;if(manual)$('guide-request').textContent='状态刷新已入队，等待FPGA读回';}
 catch(e){if(manual)$('guide-request').textContent='暂未刷新：'+e.message;}finally{guideBusy=false;}
}
async function pollGuide(){
 if(guideReading)return;guideReading=true;
 try{
  if(guideRefreshJob){const j=await api('/api/extensions/job');if(j.id!==guideRefreshJob||!j.running){if(j.id===guideRefreshJob&&!j.ok)$('guide-request').textContent='刷新失败：'+j.message;guideRefreshJob=0;}}
  const s=await api('/api/guide/state');paintGuide(s);
  if(s.refresh_allowed&&!s.pending&&(!s.fresh||s.age_ms>=1500))await refreshGuide();
 }catch(e){invalidateGuide('无法读取实际状态：'+e.message);}finally{guideReading=false;setTimeout(pollGuide,1500);}
}
// Expire a visible snapshot even while a slow/offline HTTP request is pending.
function expireGuide(){if(guideCache?.fresh&&Date.now()-guideReceivedAt+guideCache.age_ms>3000)invalidateGuide('本地等待已超过3秒，缓存过期');setTimeout(expireGuide,500);}
$('guide-mode-submit').onclick=()=>guideCommand('/api/guide/mode',{mode:Number($('guide-mode').value)});
document.querySelectorAll('[data-guide-action]').forEach(b=>b.onclick=()=>guideCommand('/api/guide/control',{song:Number($('guide-song').value),action:Number(b.dataset.guideAction)}));
$('guide-refresh').onclick=()=>refreshGuide(true);
function save(name,o){const u=URL.createObjectURL(new Blob([JSON.stringify(o,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);}
function paintMap(o){V041.mapping(o);mappingDisabled=!!o.disabled;for(const k of ['notes','pads','cc'])o[k].forEach((v,i)=>$(k+'-'+i).value=v);}
function readMap(){const o=V041.defaults();for(const k of ['notes','pads','cc'])o[k]=o[k].map((_,i)=>Number($(k+'-'+i).value));o.panic_before_commit=$('map-panic').checked;o.disabled=mappingDisabled;return V041.mapping(o);}
for(const [k,n,labels] of [['notes',128,null],['pads',4,['Kick','Snare','Closed Hat','Open Hat']],['cc',4,['Delay','Chorus','Reverb','Volume']]])for(let i=0;i<n;i++){const l=document.createElement('label');l.textContent=k==='notes'?'Note '+i:(labels[i]+' 来源');const v=document.createElement('input');v.type='number';v.min=0;v.max=127;v.id=k+'-'+i;v.oninput=()=>{mappingDisabled=false;};v.setAttribute('aria-label',l.textContent);l.append(v);$(k).append(l);}paintMap(V041.defaults());
$('score-upload').onclick=()=>{try{const o=JSON.parse($('score').value);V041.score(o);job('/api/scores',o);}catch(e){notice(e.message,true);}};
$('score-file').onchange=async()=>{try{const f=$('score-file').files[0];if(!f)return;if(f.size>16384)throw Error('曲谱文件最多16384字节');const text=await f.text();V041.score(JSON.parse(text));$('score').value=text;notice('曲谱导入有效，尚未上传');}catch(e){notice(e.message,true);}};
$('score-fetch').onclick=async()=>{const c=new AbortController(),t=setTimeout(()=>c.abort(),15000);try{const url=new URL($('score-url').value);if(!['https:','http:'].includes(url.protocol))throw Error('需要HTTP(S) URL');const r=await fetch(url.href,{mode:'cors',signal:c.signal});if(!r.ok)throw Error('HTTP '+r.status);const text=await r.text();if(new TextEncoder().encode(text).length>16384)throw Error('在线文件超过16384字节');V041.score(JSON.parse(text));$('score').value=text;notice('在线读取成功，尚未上传FPGA');}catch(e){notice('在线读取失败（网络/CORS/格式）：'+e.message+'。请联网下载JSON后使用文件导入。',true);}finally{clearTimeout(t);}};
$('score-list').onclick=async()=>{try{const s=await api('/api/scores');$('library').textContent=s.scores.length?'已保存自定义曲谱 uploaded，可下载JSON。':'尚无上传曲谱；预置三曲不是在线曲库。';}catch(e){notice(e.message,true);}};
document.querySelectorAll('[data-guide]').forEach(b=>b.onclick=()=>guideCommand('/api/scores/control',{action:Number(b.dataset.guide)}));
$('map-load').onclick=async()=>{try{const o=await api('/api/mapping');const confirmed=o.active_confirmed;delete o.active_confirmed;paintMap(o);$('map-state').textContent=confirmed?(o.disabled?'FPGA已禁用自定义映射，精确V040默认含GM别名':'FPGA本次连接已确认自定义映射生效'):'仅保存/默认值，尚未确认本次FPGA生效';}catch(e){notice(e.message,true);}};
$('map-identity').onclick=()=>{paintMap(V041.defaults());notice('编辑框已恢复默认，尚未提交');};
$('map-submit').onclick=()=>{try{job('/api/mapping',readMap(),'PUT');}catch(e){notice(e.message,true);}};
$('map-default').onclick=()=>job('/api/mapping/default',{panic_before_commit:$('map-panic').checked});
$('map-export').onclick=()=>{try{save('Tang20K-mapping.json',readMap());}catch(e){notice(e.message,true);}};
$('map-file').onchange=async()=>{try{const f=$('map-file').files[0];if(!f)return;if(f.size>4096)throw Error('映射文件最多4096字节');const o=JSON.parse(await f.text());paintMap(o);$('map-panic').checked=!!o.panic_before_commit;notice('映射已导入编辑框，尚未提交');}catch(e){notice(e.message,true);}};
$('rec-start').onclick=()=>job('/api/recordings/start',{seconds:Number($('seconds').value)});
$('rec-stop').onclick=async()=>{try{await api('/api/recordings/stop','POST',{});notice('请求停止，等待EOF、排空和CRC；尚未完成');}catch(e){notice(e.message,true);}};
$('rec-play').onclick=()=>{if(!lastWav){notice('没有可播放的已校验WAV',true);return;}$('player').src='/api/recordings/last.wav?play=1&t='+Date.now();$('player').play().catch(e=>notice('播放失败，可下载WAV：'+e.message,true));};
$('format').onclick=async()=>{if(!confirm('清空LittleFS中的曲谱、映射和录音并初始化？'))return;try{await api('/api/storage/format','POST',{confirm:'FORMAT_LITTLEFS'});notice('LittleFS初始化完成');}catch(e){notice(e.message,true);}};
async function poll(){try{
 if(currentJob){const j=await api('/api/extensions/job');if(j.id!==currentJob&&j.id)currentJob=j.id;if(j.id===currentJob){$('progress').max=j.total||1;$('progress').value=j.progress;if(!j.running){notice(j.message+(j.ok?'':'（未成功，错误 '+j.error+'）'),!j.ok);if(j.id===guideControlJob){$('guide-request').textContent=j.message;guideControlJob=0;}currentJob=0;}}}
 const r=await api('/api/recordings/current');$('rec-state').textContent=(r.fs_ready?'LittleFS可用':'LittleFS未挂载，需明确初始化')+' · 当前可录上限 '+r.max_seconds+'秒\n状态 '+r.state+' · '+r.seconds+'秒 · PCM样本 '+r.samples+' · drops '+r.drops+'\n'+(r.error||'');
 lastWav=!!r.saved_available||!!r.valid;$('rec-play').disabled=!lastWav;$('seconds').max=r.max_seconds;$('rec-start').disabled=!r.fs_ready||r.max_seconds<1||['recording','finalizing'].includes(r.state);$('wav-download').style.display=lastWav?'inline':'none';
 }catch(e){$('rec-state').textContent='无法获取当前状态：'+e.message;lastWav=false;$('rec-play').disabled=true;}finally{setTimeout(poll,750);}}
poll();pollGuide();expireGuide();
</script></html>)V041HTML";
