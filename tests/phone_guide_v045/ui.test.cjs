'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../..'),html=fs.readFileSync(path.join(root,'esp32_phone/v041_ui.h'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];new vm.Script(script);
const box={};vm.runInNewContext(script.slice(script.indexOf('const V041='),script.indexOf('const $='))+';globalThis.v=V041;',box);
let checks=0;const ok=x=>{++checks;assert.ok(x);};
const state=(changes={})=>({raw:0,mode:0,roll_song:0,selected_song:0,active:false,done:false,practice_hold:false,external_suspend:false,step:0,expected_note:0,expected_valid:false,fresh:true,verified:true,stale:false,age_ms:0,ttl_ms:3000,pending:false,refresh_allowed:false,error:'',...changes});
const modes=['固定BPM检验','自动演奏','逐音练习'],songs=['小星星','灯阶练习曲','溪桥练习曲','自定义'];
for(let mode=0;mode<3;mode++)for(let song=0;song<4;song++){
 const s=state({mode,selected_song:song,roll_song:(song+1)%4,step:63,expected_note:127,expected_valid:true});const v=box.v.guideView(s);
 ok(v.fresh&&!v.bad&&v.text.includes(modes[mode]));ok(v.text.includes('已选曲目：'+songs[song])&&v.text.includes('滚动曲目：'+songs[(song+1)%4]));ok(v.text.includes('step 63')&&v.text.includes('目标音 127'));
}
for(const [field,label] of [['active','运行'],['done','已完成'],['practice_hold','等待目标音'],['external_suspend','外部暂停']])ok(box.v.guideView(state({[field]:true})).text.includes(label));
ok(box.v.guideView(state({expected_note:64,expected_valid:false})).text.includes('目标音 无'));
for(const s of [state({fresh:false}),state({verified:false}),state({age_ms:3001}),state({ttl_ms:9999}),state({mode:3}),state({selected_song:4}),state({expected_note:128}),state({step:64}),{},null])ok(!box.v.guideView(s).fresh);
ok(box.v.guideView(state({fresh:false,verified:false,error:'op22超时'})).text.includes('op22超时'));
for(const bpm of [120,112,100])ok(html.includes(bpm+' BPM'));
ok(html.includes('value="0">固定BPM检验')&&html.includes('value="1">自动演奏')&&html.includes('value="2">逐音练习'));

async function handlers(){
 const elements=new Map(),requests=[],timers=[];let next=0,failPath='',failCode=0,clock=1000;
 let actual=state(),lastJob={id:0,running:false,ok:true,message:'空闲'};
 class Element{
  constructor(){this.value='';this.checked=false;this.style={};this.dataset={};this.children=[];this.textContent='';}
  set id(v){this._id=v;elements.set(v,this);}get id(){return this._id;}
  append(...x){this.children.push(...x);}setAttribute(){}click(){}play(){return Promise.resolve();}
 }
 const get=k=>{if(!elements.has(k)){const e=new Element();e.id=k;}return elements.get(k);};
 const controls=[0,1,2,3].map(n=>{const e=new Element();e.dataset.guideAction=String(n);return e;});
 const legacy=[0,1,2,3].map(n=>{const e=new Element();e.dataset.guide=String(n);return e;});
 const sandbox={console,URL,Blob,TextEncoder,AbortController,Date:{now:()=>clock},confirm:()=>true,setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length;},clearTimeout(){},document:{getElementById:get,createElement:()=>new Element(),querySelectorAll:q=>q==='[data-guide-action]'?controls:q==='[data-guide]'?legacy:[]},fetch:async(p,opt={})=>{
  requests.push({p,opt});if(p===failPath){if(!failCode)throw Error('offline');return {ok:false,status:failCode,json:async()=>({error:'模拟错误 '+failCode})};}
  let data;
  if(p==='/api/guide/state'&&(opt.method||'GET')==='GET')data={...actual};
  else if(p==='/api/extensions/job')data={...lastJob};
  else if(p==='/api/recordings/current')data={fs_ready:true,max_seconds:30,state:'idle',samples:0,drops:0,seconds:0,saved_available:false};
  else {lastJob={id:++next,running:true,ok:false,progress:0,total:2,request_accepted:false,state_verified:false,message:'等待FPGA能力确认'};data={...lastJob};}
  return {ok:true,json:async()=>data};
 }};
 vm.createContext(sandbox);vm.runInContext(script,sandbox);const settle=()=>new Promise(resolve=>setImmediate(resolve));await settle();
 for(let song=0;song<4;song++)for(let action=0;action<4;action++){
  get('guide-song').value=String(song);await controls[action].onclick();const r=requests.at(-1);
  ok(r.p==='/api/guide/control'&&r.opt.method==='POST');assert.deepEqual(JSON.parse(r.opt.body),{song,action});checks++;
  ok(get('guide-state').textContent.includes('不能视为当前状态'));
 }
 for(let mode=0;mode<3;mode++){
  get('guide-mode').value=String(mode);await get('guide-mode-submit').onclick();const r=requests.at(-1);ok(r.p==='/api/guide/mode'&&JSON.parse(r.opt.body).mode===mode);
  ok(get('guide-request').textContent.includes('ACK只代表接受'));
 }
 // Requested mode/song stay separate from readback and never replace it.
 get('guide-mode').value='2';get('guide-song').value='3';sandbox.paintGuide(state({mode:1,selected_song:0,roll_song:2,external_suspend:true}));
 ok(get('guide-state').textContent.includes('模式：自动演奏')&&get('guide-state').textContent.includes('已选曲目：小星星')&&get('guide-state').textContent.includes('滚动曲目：溪桥练习曲'));
 ok(get('guide-mode').value==='2'&&get('guide-song').value==='3');
 // Readback failure cannot be promoted by successful request ACK.
 lastJob={...lastJob,running:false,ok:false,request_accepted:true,state_verified:false,error:10,message:'op22读回超时'};
 actual=state({fresh:false,verified:false,error:'op22读回超时'});await sandbox.poll();await sandbox.pollGuide();
 ok(get('job').className.includes('error')&&get('job').textContent.includes('op22读回超时'));
 ok(get('guide-state').className.includes('error')&&!get('guide-state').textContent.includes('FPGA实际状态 · 已读回'));
 for(const code of [409,422,429,503]){
  failPath='/api/guide/mode';failCode=code;await get('guide-mode-submit').onclick();ok(get('guide-request').textContent.includes('请求失败')&&get('guide-request').textContent.includes(String(code)));
 }
 failPath='';failCode=0;
 // No refresh while the server marks recording/busy, or a foreground job exists.
 vm.runInContext('currentJob=0;guideRefreshJob=0;',sandbox);actual=state({fresh:false,refresh_allowed:false});let count=requests.filter(r=>r.p==='/api/guide/state'&&r.opt.method==='POST').length;
 await sandbox.pollGuide();ok(requests.filter(r=>r.p==='/api/guide/state'&&r.opt.method==='POST').length===count);
 actual=state({fresh:false,refresh_allowed:true});await sandbox.pollGuide();ok(requests.filter(r=>r.p==='/api/guide/state'&&r.opt.method==='POST').length===count+1);
 await sandbox.refreshGuide(true);ok(requests.filter(r=>r.p==='/api/guide/state'&&r.opt.method==='POST').length===count+1); // coalesced
 lastJob={...lastJob,running:false,ok:true,state_verified:true,message:'已读回导奏实际状态'};actual=state();await sandbox.pollGuide();ok(get('guide-state').textContent.includes('FPGA实际状态 · 已读回'));
 // Cached GET failures and local expiry degrade the display immediately.
 failPath='/api/guide/state';await sandbox.pollGuide();ok(get('guide-state').textContent.includes('无法读取实际状态')&&get('guide-state').className.includes('error'));
 failPath='';clock=1000;sandbox.paintGuide(state({age_ms:100}));clock=4001;sandbox.expireGuide();ok(get('guide-state').textContent.includes('缓存过期')&&get('guide-state').className.includes('error'));
 // Refreshes are scheduled at 1500ms, independent of the recording status loop.
 ok(timers.some(t=>t.fn===sandbox.pollGuide&&t.ms===1500));
 console.log(`V045_GUIDE_UI_PASS checks=${checks} actual_embedded_js=1 mode3_song4_action4=1 actual_vs_requested=1 stale_errors=1 refresh_coalescing=1`);
}
handlers().catch(e=>{console.error(e);process.exitCode=1;});
