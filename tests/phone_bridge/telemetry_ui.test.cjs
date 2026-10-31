/* Headless mocks only: no board, serial port, external HTTP or audio. */
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(require.resolve('playwright',{paths:[path.join(path.dirname(process.execPath),'..')]}));
const html=fs.readFileSync(path.join(__dirname,'../../esp32_phone/web_ui.h'),'utf8').split('R"PHONEHTML(')[1].split(')PHONEHTML";')[0];
const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'build/api-state-fixture.json'),'utf8'));
const disconnected=JSON.parse(fs.readFileSync(path.join(__dirname,'build/api-disconnected-fixture.json'),'utf8'));
// Validate the real C++ sketch serialization independently of the browser UI.
assert.equal(fixture.firmware_version,'V039');assert.equal(fixture.raw_uart_rx_bytes,0);
assert.equal(fixture.telemetry.age_ms,30);assert.equal(fixture.telemetry.fsr[0].raw,32768);
assert.equal(fixture.telemetry.fsr[1].raw,32767);assert.equal(fixture.telemetry.midi.bend,-256);
assert.equal(fixture.telemetry.midi.velocity,127);assert.equal(fixture.telemetry.midi.modulation,127);
assert.deepEqual(fixture.telemetry.beams,{electrical_a:true,electrical_b:false,blocked_a:true,blocked_b:false,enabled:true,ready:true,busy:true});
assert.deepEqual(fixture.telemetry.test,{mode:false,owned:true,requested:32,active:true,sweep:true,overrun:true,index:31});
assert.equal(disconnected.telemetry.valid,false);assert.equal(disconnected.telemetry.age_ms,null);
assert.equal(disconnected.telemetry.adc.fault,false);assert.equal(disconnected.telemetry.beams.ready,false);
const output=path.join(__dirname,'build');const temp=path.join(output,'telemetry-browser-temp');fs.mkdirSync(temp,{recursive:true});
let state=structuredClone(fixture);delete state.telemetry;const posts=[];
async function main(){
 const browser=await chromium.launch({executablePath:'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',headless:true,
  env:{...process.env,TEMP:temp,TMP:temp},args:['--disable-background-networking','--disable-component-update','--no-first-run']});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.route('**/*',route=>{
   const req=route.request(),url=new URL(req.url());if(url.hostname!=='bridge.test')return route.abort();
   if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:html});
   if(url.pathname==='/api/state')return route.fulfill({contentType:'application/json',body:JSON.stringify(state)});
   posts.push(req.postData());return route.fulfill({status:400,contentType:'application/json',body:'{"error":"unexpected write"}'});
  });
  await page.goto('http://bridge.test/');await page.waitForFunction(()=>!document.getElementById('volume').disabled);
  const status=()=>page.locator('#live-status').innerText();
  const render=()=>page.evaluate(s=>render(s),state);
  const live=()=>page.locator('#live-panel').innerText();
  assert((await status()).includes('未提供遥测'));assert.equal(await page.locator('.control').count(),15);
  state.telemetry={enabled:true,status:'unsupported',supported:false,valid:false,stale:true};await render();
  assert((await status()).includes('不支持遥测'));assert.equal(await page.locator('#volume').isEnabled(),true);
  state.telemetry={...state.telemetry,status:'probing'};await render();assert((await status()).includes('正在探测'));
  state=structuredClone(fixture);await render();
  assert((await live()).includes('RAW 0x8000 · LVL 255 · CAL 已校准'));
  assert((await live()).includes('RAW 0x7FFF · LVL 63 · CAL 已校准'));
  assert.equal(await page.locator('#fsr0-bar').getAttribute('value'),'255');
  assert((await live()).includes('VEL 127 · BEND -256 · MOD 127'));
  assert((await live()).includes('A 电平 1 / 遮挡；B 电平 0 / 未遮挡'));
  assert((await live()).includes('光电 已启用 · 就绪 · 扫弦忙'));
  assert((await live()).includes('活动声部 32 / 32 · 测试请求 32'));
  assert((await live()).includes('ADC 故障 · 采样已过期'));
  assert.equal(await page.locator('#live-fsr').getAttribute('data-stale'),'true');
  assert.equal(await page.locator('#live-panel input').count(),0);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  console.log('PASS real C++ JSON fixture / FSR hex+bars+CAL / signed BEND / ADC/MIDI/beam/test flags / mobile layout / read-only');
  // Freshness expires locally even before another /api/state response arrives.
  await page.evaluate(()=>{const now=Date.now();Date.now=()=>now+1001;paintLive();});
  assert((await status()).includes('遥测过期'));assert((await live()).includes('RAW —'));
  assert.equal(await page.locator('#fsr0-bar').getAttribute('value'),'0');
  state.telemetry.age_ms=4;state.telemetry.fsr[0]={raw:255,level:19,calibrated:false};
  state.telemetry.adc={fault:false,stale:false};state.telemetry.midi.bend=255;await render();
  assert((await live()).includes('RAW 0x00FF · LVL 19 · CAL 未校准'));assert((await live()).includes('BEND 255'));
  assert.equal(await page.locator('#live-fsr').getAttribute('data-stale'),'false');
  state.telemetry.valid=false;await render();assert((await status()).includes('等待完整'));assert((await live()).includes('RAW —'));
  state.telemetry=structuredClone(fixture.telemetry);state.telemetry.stale=true;await render();assert((await status()).includes('遥测过期'));
  state.telemetry.status='unavailable';await render();assert((await status()).includes('读取失败'));assert.equal(await page.locator('#volume').isEnabled(),true);
  state.telemetry=structuredClone(fixture.telemetry);state.telemetry.fsr=[];await render();assert((await status()).includes('格式不完整'));
  state=structuredClone(disconnected);await render();assert((await status()).includes('链路未就绪'));assert((await live()).includes('RAW —'));
  state=structuredClone(fixture);await render();assert((await live()).includes('0x8000'));
  for(const name of ['telemetry','fsr0','velocity','beams']){
   await page.locator('#file').setInputFiles({name:'bad.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({[name]:1}))});
   await page.waitForFunction(()=>document.getElementById('notice').textContent.includes('预设未应用'));
  }
  assert.equal(posts.length,0);
  const download=page.waitForEvent('download');await page.locator('#export').click();const file=await download;
  const save=path.join(output,'telemetry-preset-export.json');await file.saveAs(save);
  const preset=JSON.parse(fs.readFileSync(save,'utf8'));assert.equal(Object.keys(preset).length,15);assert(!('telemetry' in preset));
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(output,'telemetry-ui-result.json'),JSON.stringify({passed:true,errors,unexpected_posts:posts.length,hardware_access:false},null,2));
  await page.screenshot({path:path.join(output,'telemetry-ui-mobile.png'),fullPage:true});
  console.log('PASS old/missing FPGA feature / local 1s stale clears values / invalid partial / recovery / disconnect / preset isolation');
 }finally{await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
