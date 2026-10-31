const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),html=fs.readFileSync(path.join(root,'esp32_phone/v041_ui.h'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];new vm.Script(script);
const validators=script.slice(script.indexOf('const V041='),script.indexOf('const $='));const box={};vm.runInNewContext(validators+';globalThis.api=V041;',box);const v=box.api;let checks=0;
const ok=x=>{++checks;assert.ok(x);},bad=f=>{++checks;assert.throws(f);};
const base={bpm:120,events:[{pitch:60,start:0,duration:1,velocity:96},{pitch:64,start:1,duration:2,velocity:80}]};
const s=v.score(base);ok(s.total===20&&s.samples_per_beat===46875);ok(s.words[0]&(1<<23));ok(((s.words[8]>>>16)&127)===64);ok(s.words[12]&(1<<15));ok(s.words.every(w=>(w>>>31)===0));
for(const [bpm,samples] of [[30,187500],[240,23438],[97,57990]]){const x=v.score({...base,bpm});ok(x.samples_per_beat===samples);}
for(const bpm of [29,241,120.5,'120',NaN])bad(()=>v.score({...base,bpm}));
for(const e of [{pitch:40},{pitch:73},{start:0.1},{duration:0},{velocity:128},{velocity:0}])bad(()=>v.score({...base,events:[{...base.events[0],...e}]}));
bad(()=>v.score({...base,events:[base.events[1],base.events[0]]}));bad(()=>v.score({...base,total_beats:64}));bad(()=>v.score({...base,total_quarters:4}));bad(()=>v.score({...base,extra:1}));bad(()=>v.score({...base,events:Array(64).fill(base.events[0])}));
ok(v.score({bpm:30,total_beats:61,events:[{note:41,start_quarter:0,duration_quarters:244,velocity:127}]}).total===252);
let m=v.defaults();ok(m.notes.length===128&&m.pads.join(',')==='36,38,37,39'&&m.cc.join(',')==='93,91,71,74');v.mapping(m);checks++;
[m.notes[0],m.notes[127]]=[m.notes[127],m.notes[0]];v.mapping(m);checks++;m.notes[2]=m.notes[1];bad(()=>v.mapping(m));
for(const field of ['notes','pads','cc']){const q=v.defaults();q[field].pop();bad(()=>v.mapping(q));}m=v.defaults();m.cc[0]=64;bad(()=>v.mapping(m));
for(const route of ['/api/scores/control','/api/scores','/api/mapping','/api/recordings/start','/api/recordings/last.wav'])ok(script.includes(route)||html.includes(route));
ok(html.includes('data-guide="1"')&&html.includes('data-guide="2"')&&html.includes('data-guide="3"'));ok(!script.includes('getUserMedia')&&!script.includes('MediaRecorder'));ok(script.includes("mode:'cors'")&&script.includes('CORS/格式'));
const contract=JSON.parse(fs.readFileSync(path.join(root,'docs/phone_extensions_protocol.json'),'utf8'));
ok(JSON.stringify(Array.from(v.defaults().pads))===JSON.stringify(Object.values(contract.default_pad_targets)));
ok(contract.ops['38'].includes('MAP_DISABLE')&&v.defaults().disabled===true);
async function pageHandlers(){
 const elements=new Map(),requests=[];let id=0;
 class Element{
  constructor(){this.value='';this.checked=false;this.style={};this.dataset={};this.children=[];this.textContent='';}
  set id(v){this._id=v;elements.set(v,this);}get id(){return this._id;}
  append(...x){this.children.push(...x);}setAttribute(){}click(){}play(){return Promise.resolve();}
 }
 const get=k=>{if(!elements.has(k)){const e=new Element();e.id=k;}return elements.get(k);};
 const guides=[0,1,2,3].map(n=>{const e=new Element();e.dataset.guide=String(n);return e;});
 const sandbox={console,URL,Blob,TextEncoder,AbortController,Date,confirm:()=>true,setTimeout:()=>1,clearTimeout(){},document:{getElementById:get,createElement:()=>new Element(),querySelectorAll:()=>guides},fetch:async(p,opt={})=>{
  requests.push({p,opt});if(String(p).startsWith('https://'))throw Error('offline network/CORS');
  const data=p==='/api/recordings/current'?{fs_ready:true,max_seconds:30,state:'idle',samples:0,frames:0,drops:0,seconds:0,saved_available:false}:p==='/api/mapping'?{...JSON.parse(JSON.stringify(v.defaults())),active_confirmed:true}:p==='/api/scores'?{scores:[]}:{id:++id,running:true,progress:0,total:10};
  return {ok:true,json:async()=>data};
 }};
 vm.runInNewContext(script,sandbox);const settle=()=>new Promise(resolve=>setImmediate(resolve));await settle();
 ok(get('notes').children.length===128&&get('pads').children.length===4&&get('cc').children.length===4);
 for(let n=0;n<4;n++){await guides[n].onclick();await settle();const q=requests.filter(r=>r.p==='/api/scores/control').at(-1);ok(JSON.parse(q.opt.body).action===n);}
 get('score').value=JSON.stringify(base);get('score-upload').onclick();await settle();ok(requests.some(r=>r.p==='/api/scores'&&r.opt.method==='POST'));
 const before=requests.length;get('score').value=JSON.stringify({...base,bpm:10});get('score-upload').onclick();await settle();ok(requests.length===before&&get('job').className.includes('error'));
 await get('map-load').onclick();ok(get('map-state').textContent.includes('GM'));
 get('map-panic').checked=true;await get('map-default').onclick();await settle();ok(JSON.parse(requests.filter(r=>r.p==='/api/mapping/default').at(-1).opt.body).panic_before_commit===true);
 get('notes-0').oninput();await get('map-submit').onclick();await settle();const mapRequest=requests.filter(r=>r.p==='/api/mapping'&&r.opt.method==='PUT').at(-1);ok(JSON.parse(mapRequest.opt.body).disabled===false);
 get('score-file').files=[{size:JSON.stringify(base).length,text:async()=>JSON.stringify(base)}];await get('score-file').onchange();ok(get('job').textContent.includes('尚未上传'));
 get('score-url').value='https://offline.invalid/score.json';await get('score-fetch').onclick();ok(get('job').textContent.includes('CORS')&&get('job').className.includes('error'));
 get('seconds').value='30';await get('rec-start').onclick();await settle();ok(JSON.parse(requests.filter(r=>r.p==='/api/recordings/start').at(-1).opt.body).seconds===30);
 await get('rec-stop').onclick();ok(requests.some(r=>r.p==='/api/recordings/stop'));
 await get('format').onclick();ok(JSON.parse(requests.filter(r=>r.p==='/api/storage/format').at(-1).opt.body).confirm==='FORMAT_LITTLEFS');
 console.log(`V041_ESP_UI_PASS checks=${checks} actual_embedded_validators=1 mocked_page_handlers=1 guide4=1 files_url_mapping_recording=1 offline_only=1`);
}
pageHandlers().catch(e=>{console.error(e);process.exitCode=1;});

for (const cc of [1,7,64,120,121,123]){const q=v.defaults();q.cc[0]=cc;bad(()=>v.mapping(q));}
