// Exercise the same score codec embedded in the shipped phone UI, offline.
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const h=fs.readFileSync('esp32_phone/v041_ui.h','utf8');
const script=h.match(/<script>([\s\S]*?)<\/script>/)[1],box={};
vm.runInNewContext(script.slice(script.indexOf('const V041='),script.indexOf('const $='))+';this.v=V041;',box);
const codec=box.v;let scores=0;
for(const name of fs.readdirSync('examples/V047').filter(n=>n.endsWith('.json'))){
  const o=JSON.parse(fs.readFileSync('examples/V047/'+name,'utf8'));
  if(!o.schema.startsWith('tang20k.score/'))continue;
  const s=codec.score(o);
  for(let q=0;q<s.total;q++){
    const e=o.events.find(e=>q>=e.start*4+8&&q<(e.start+e.duration)*4+8);
    const w=s.words[q];let notes=[];
    if(w&(1<<13)){notes=[w&127];if(w>>>31)for(let j=0;j<3;j++){
      const d=(w>>>(16+j*5))&31;if(d)notes.push(notes[0]+d);
    }}
    assert.deepStrictEqual(notes,e?(e.pitches||[e.pitch]):[]);
    if(e)assert.equal(!!(w&(1<<14)),q===e.start*4+8);
  }
  scores++;
}
assert(scores>=2,'Missing original upload score examples');
const base={schema:'tang20k.score/2',bpm:120,events:[{pitches:[41,53,60,72],start:0,duration:1,velocity:96}]};
codec.score(base);let rejected=0;
for(const pitches of [[],[60,60],[72,41],[40,60],[60,73],[50,54,58,62,66],[60,61.5]]){
  assert.throws(()=>codec.score({...base,events:[{...base.events[0],pitches}]}));rejected++;
}
console.log(`SCORE_CODEC_PASS ${scores} examples; ${rejected} invalid chords rejected; no hardware access`);
