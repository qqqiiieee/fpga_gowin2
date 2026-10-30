/* Offline browser test: all HTTP is intercepted, no board/network/serial access. */
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'../../esp32_phone');
const html=fs.readFileSync(path.join(root,'web_ui.h'),'utf8').split('R"PHONEHTML(')[1].split(')PHONEHTML";')[0];
assert(!/getUserMedia|MediaRecorder|<audio|<video/.test(html));
const keys=['volume','timbre','input_mode','fx_mode','fx_wet','fx_time','fx_feedback','fx_modulation','attack','decay','sustain','release','hdmi_page','filter','digital_zero','status_flags'];
const max=[255,1,2,3,255,255,255,255,255,255,255,255,3,1,1,127];
let revision=0,getFailure=false,postFailure=false;
const posts=[];
let state={boot_id:123,linked:true,synced:true,stale:false,ack_age_ms:4,queued:0,inflight:false,tx:30,rx:30,retries:0,ignored:0,
  panic:{requested:0,applied:0,failed:0,error:0},params:Object.fromEntries(keys.map((k,i)=>[k,{value:i===0?40:0,valid:true,requested:0,applied:0,failed:0,error:0}]))};
const output=path.join(__dirname,'build');fs.mkdirSync(output,{recursive:true});
const tmp=path.join(output,'browser-temp');fs.mkdirSync(tmp,{recursive:true});
process.env.TEMP=tmp;process.env.TMP=tmp;
async function main(){
 const browserExecutable=process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
 if(browserExecutable&&!fs.existsSync(browserExecutable))throw new Error('PLAYWRIGHT_CHROMIUM_EXECUTABLE does not exist: '+browserExecutable);
 const context=await chromium.launchPersistentContext(path.join(output,'browser-profile'),{
  ...(browserExecutable?{executablePath:browserExecutable}:{}),headless:true,
  viewport:{width:390,height:844},deviceScaleFactor:1,
  env:{...process.env,TEMP:tmp,TMP:tmp},args:['--disable-background-networking','--disable-component-update','--no-first-run']});
 const page=context.pages()[0]||await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 try{
  await context.route('**/*',async route=>{
   const req=route.request(),url=new URL(req.url());
   const json=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
   if(url.hostname!=='bridge.test')return route.abort();
   if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:html});
   if(url.pathname==='/api/state'){
    if(getFailure)return route.abort('failed');
    return json(state);
   }
   if(url.pathname==='/api/apply'||url.pathname==='/api/panic'){
    posts.push({path:url.pathname,raw:req.postData()});
    if(postFailure)return json({error:'模拟服务器拒绝'},503);
    if(url.pathname==='/api/panic'){state.panic.requested=++revision;return json({accepted:true,revision},202);}
    const raw=req.postData();let obj;try{obj=JSON.parse(raw);}catch{return json({error:'JSON非法'},400);}
    const names=[...raw.matchAll(/"([a-z_]+)"\s*:/g)].map(m=>m[1]);
    if(new Set(names).size!==names.length)return json({error:'重复字段，整份拒绝'},400);
    for(const [k,v] of Object.entries(obj))if(!keys.includes(k)||k==='status_flags'||!Number.isInteger(v)||v<0||v>max[keys.indexOf(k)])return json({error:'字段非法'},400);
    ++revision;for(const k of Object.keys(obj))state.params[k].requested=revision;
    return json({accepted:true,revision},202);
   }
   return route.fulfill({status:404,body:''});
  });
  const render=()=>page.evaluate(s=>render(s),state);
  const notice=()=>page.locator('#notice').innerText();
  const waitNotice=s=>page.waitForFunction(text=>document.getElementById('notice').textContent.includes(text),s);
  const waitPosts=async n=>{for(let i=0;i<150&&posts.length<n;++i)await page.waitForTimeout(20);assert.equal(posts.length,n);};
  const change=async(key,value)=>page.evaluate(({key,value})=>{const el=document.getElementById(key);el.value=value;el.dispatchEvent(new Event('input'));el.dispatchEvent(new Event('change'));},{key,value});
  const importFile=async text=>page.locator('#file').setInputFiles({name:'test.json',mimeType:'application/json',buffer:Buffer.from(text)});
  await page.goto('http://bridge.test/');await waitNotice('完整回读完成');
  assert.equal(await page.locator('.control').count(),15);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  assert.equal(await page.locator('#volume').isEnabled(),true);
  await page.screenshot({path:path.join(output,'phone-ui-mobile.png'),fullPage:true});
  console.log('PASS mobile UI / 15 parameters / no overflow / no fake audio');

  await page.locator('#volume').focus();await change('volume',111);await waitPosts(1);await waitNotice('请求已入队');
  assert(!(await notice()).includes('FPGA 已确认'));assert((await page.locator('#volume').locator('..').innerText()).includes('40'));
  state.params.volume.value=109;state.params.volume.failed=revision;state.params.volume.error=12;await render();await waitNotice('控制冲突');
  assert(!(await notice()).includes('FPGA 已确认'));assert((await notice()).includes('目标 111，实际 109'));
  assert((await page.locator('#volume').locator('..').innerText()).includes('实际值：109'));
  assert.equal(await page.locator('#volume').inputValue(),'109');
  await change('timbre',1);await waitPosts(2);await waitNotice('请求已入队');
  state.params.timbre.failed=revision;state.params.timbre.error=2;await render();await waitNotice('设置失败');
  assert(!(await notice()).includes('FPGA 已确认'));
  state.params.volume.value=203;await render();assert((await page.locator('#volume').locator('..').innerText()).includes('203'));
  assert((await notice()).includes('失败'));
  console.log('PASS acceptance != ACK / actual-target conflict / RESULT error / physical volume readback');

  await importFile('{"fx_wet":150,"attack":40}');await waitPosts(3);await waitNotice('请求已入队');
  state.params.fx_wet.failed=revision;state.params.fx_wet.error=3;await render();await waitNotice('设置失败');
  state.params.attack.value=40;state.params.attack.applied=revision;await render();
  assert((await notice()).includes('失败'));assert(!(await notice()).includes('FPGA 已确认'));
  const beforeInvalid=posts.length;
  for(const bad of ['{"unknown":1}','{"volume":2,"timbre":2}','{"status_flags":0}','{"volume":1.5}','{"volume":true}','[]','{}']){
    await importFile(bad);await waitNotice('预设未应用');assert.equal(posts.length,beforeInvalid);
  }
  await importFile('{"volume":1,"volume":2}');await waitPosts(4);await waitNotice('写请求失败');
  assert(!(await notice()).includes('FPGA 已确认'));await page.waitForTimeout(450);
  console.log('PASS invalid preset no application / duplicate rejected by server / mixed batch error stays error');

  await page.waitForFunction(()=>!document.getElementById('fx_wet').disabled);
  await page.evaluate(()=>{for(let i=0;i<100;++i){const el=document.getElementById('fx_wet');el.value=i;el.dispatchEvent(new Event('change'));}});
  await waitPosts(5);await waitNotice('请求已入队');assert.deepEqual(JSON.parse(posts[4].raw),{fx_wet:99});
  state.params.fx_wet.value=99;state.params.fx_wet.applied=revision;await render();await waitNotice('FPGA 已确认');
  await change('fx_time',44);await waitPosts(6);await waitNotice('请求已入队');
  state.linked=false;state.synced=false;state.stale=true;for(const p of Object.values(state.params))p.valid=false;
  await render();assert.equal(await page.locator('#volume').isDisabled(),true);assert((await page.locator('#link').innerText()).includes('过期'));
  assert(!(await notice()).includes('FPGA 已确认'));
  state.linked=true;await render();assert.equal(await page.locator('#volume').isDisabled(),true);
  state.synced=true;state.stale=false;for(const p of Object.values(state.params))p.valid=true;
  await render();await page.waitForTimeout(550);assert.equal(posts.length,6);assert.equal(await page.locator('#volume').isEnabled(),true);
  console.log('PASS rapid edit coalesce / stale disables / recovery readback / no stale write replay');

  getFailure=true;await page.waitForFunction(()=>document.getElementById('volume').disabled);
  assert((await page.locator('#link').innerText()).includes('手机无法'));
  getFailure=false;await page.waitForFunction(()=>!document.getElementById('volume').disabled);
  await page.locator('#panic').click();await waitPosts(7);await waitNotice('Panic 已入队');
  assert(!(await notice()).includes('FPGA 已确认'));
  state.panic.failed=revision;state.panic.error=1;await render();await waitNotice('Panic 失败');
  await page.locator('#panic').click();await waitPosts(8);await waitNotice('Panic 已入队');
  state.panic.applied=revision;await render();await waitNotice('FPGA 已确认 Panic');
  state.boot_id++;state.synced=false;state.stale=true;await render();assert.equal(await page.locator('#volume').isDisabled(),true);
  state.synced=true;state.stale=false;await render();
  await change('digital_zero',0);await waitPosts(9);await waitNotice('请求已入队');
  state.params.digital_zero.value=1;state.params.digital_zero.failed=revision;state.params.digital_zero.error=12;
  state.params.status_flags.value=64;await render();await waitNotice('目标 0，实际 1');
  assert((await notice()).includes('控制冲突'));assert(!(await notice()).includes('FPGA 已确认'));
  assert((await page.locator('#digital_zero').locator('..').innerText()).includes('实际值：1'));
  const downloadPromise=page.waitForEvent('download');await page.locator('#export').click();const download=await downloadPromise;
  const save=path.join(output,'exported-preset.json');await download.saveAs(save);const exported=JSON.parse(fs.readFileSync(save,'utf8'));
  assert.equal(Object.keys(exported).length,15);assert.equal(exported.volume,203);assert(!Object.hasOwn(exported,'status_flags'));

  assert.deepEqual(await page.locator('#input_mode option').evaluateAll(options=>options.map(o=>({value:o.value,text:o.textContent}))),[
    {value:'0',text:'KEY 键盘'},{value:'1',text:'STRUM 扫弦'},{value:'2',text:'HYBRID 混合（键盘＋扫弦）'}]);
  const beforeModes=posts.length;
  // Mode 2 is submitted normally, but HTTP acceptance cannot confirm its value.
  await page.locator('#input_mode').selectOption('2');await waitPosts(beforeModes+1);await waitNotice('请求已入队');
  assert.deepEqual(JSON.parse(posts.at(-1).raw),{input_mode:2});
  assert(!(await notice()).includes('FPGA 已确认'));
  assert((await page.locator('#input_mode').locator('..').innerText()).includes('实际值：0'));
  state.params.input_mode.value=1;state.params.input_mode.failed=revision;state.params.input_mode.error=12;
  state.params.status_flags.value=16;await render();await waitNotice('目标 2，实际 1');
  assert.equal(await page.locator('#input_mode').inputValue(),'1');assert(!(await notice()).includes('FPGA 已确认'));
  await page.locator('#input_mode').selectOption('2');await waitPosts(beforeModes+2);await waitNotice('请求已入队');
  state.params.input_mode.value=2;state.params.input_mode.applied=revision;await render();await waitNotice('FPGA 已确认');
  assert.equal(await page.locator('#input_mode').inputValue(),'2');
  await page.locator('details summary').click();
  assert((await page.locator('#flags').innerText()).includes('光电输入已启用（STRUM / HYBRID，bit4）：true'));
  // Mode 3 is rejected locally, including mixed presets: no partial POST.
  const beforeBadMode=posts.length;
  for(const bad of ['{"input_mode":3}','{"volume":40,"input_mode":3}']){
    await importFile(bad);await waitNotice('input_mode 必须为 0–2 的整数');assert.equal(posts.length,beforeBadMode);
  }
  await importFile('{"input_mode":2}');await waitPosts(beforeModes+3);await waitNotice('请求已入队');
  assert.deepEqual(JSON.parse(posts.at(-1).raw),{input_mode:2});
  assert(!(await notice()).includes('FPGA 已确认'));
  state.params.input_mode.applied=revision;await render();await waitNotice('FPGA 已确认');
  const hybridDownload=page.waitForEvent('download');await page.locator('#export').click();
  const hybridSave=path.join(output,'exported-hybrid-preset.json');await (await hybridDownload).saveAs(hybridSave);
  assert.equal(JSON.parse(fs.readFileSync(hybridSave,'utf8')).input_mode,2);
  // External panel changes must update the selector without echoing a write.
  const beforeExternal=posts.length;
  for(const mode of [0,1,2]){
    state.params.input_mode.value=mode;state.params.status_flags.value=mode?16:0;await render();
    assert.equal(await page.locator('#input_mode').inputValue(),String(mode));
    assert((await page.locator('#flags').innerText()).includes('bit4）：'+(mode!==0)));
  }
  await page.waitForTimeout(450);assert.equal(posts.length,beforeExternal);
  console.log('PASS three input modes / HYBRID requires actual ACK / conflict / invalid 3 no POST / preset roundtrip / external readback');
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(output,'web-test-result.json'),JSON.stringify({passed:true,posts:posts.length,errors,hardware_access:false},null,2));
  console.log('PASS phone heartbeat loss / Panic ACK and error / restart / FTDI actual mute conflict / JSON export');
  console.log('ALL OFFLINE WEB UI TESTS PASSED');
 }finally{await context.close();}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
