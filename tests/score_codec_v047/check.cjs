const fs=require('fs'),vm=require('vm'),assert=require('assert');
const root=process.cwd(),h=fs.readFileSync('esp32_phone/v041_ui.h','utf8'),script=h.match(/<script>([\s\S]*?)<\/script>/)[1];
const box={};vm.runInNewContext(script.slice(script.indexOf('const V041='),script.indexOf('const $='))+';this.v=V041;',box);const v=box.v;
const sources=['霓虹阶梯_黑白键双音四音_V047.json','上传验证_兼容V046单音.json'];let results=[];
for(const name of sources){const o=JSON.parse(fs.readFileSync('examples/V047/'+name,'utf8'));const s=v.score(o);
 for(let q=0;q<s.total;q++){const e=o.events.find(e=>q>=e.start*4+8&&q<(e.start+e.duration)*4+8);const w=s.words[q];let notes=[];
 if(w&(1<<13)){notes=[w&127];if(w>>>31)for(let j=0;j<3;j++){const d=(w>>>(16+j*5))&31;if(d)notes.push(notes[0]+d);}}
 assert.deepStrictEqual(notes,e?(e.pitches||[e.pitch]):[]);
 if(e)assert.equal(!!(w&(1<<14)),q===e.start*4+8);
 }
 results.push({name,words:Array.from(s.words),sum:s.sum,total:s.total,source:o});
}
const base={schema:'tang20k.score/2',bpm:120,events:[{pitches:[41,53,60,72],start:0,duration:1,velocity:96}]};v.score(base);
let rejects=0;for(const pitches of [[],[60,60],[72,41],[40,60],[60,73],[50,54,58,62,66],[60,61.5]]){assert.throws(()=>v.score({...base,events:[{...base.events[0],pitches}]}));rejects++;}
for(const extra of [{pitch:60},{note:60}])assert.throws(()=>v.score({...base,events:[{...base.events[0],...extra}]}));
assert.throws(()=>v.score({...base,schema:'tang20k.score/1'}));assert.throws(()=>v.score({...base,events:[...base.events,{pitches:[62,66],start:.5,duration:1,velocity:96}]}));
const map=JSON.parse(fs.readFileSync('examples/V047/映射演示_交换C4与D4.json','utf8'));v.mapping(map);assert.equal(map.notes[60],62);assert.equal(map.notes[62],60);
fs.writeFileSync('tests/score_codec_v047/js.json',JSON.stringify({passed:true,invalid_chords_rejected:rejects,results},null,2));console.log('V047_JS_SCORE_PASS',results.map(x=>x.name),rejects);
