import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectFrameEvents, editFrameEvents } from './model-events.mjs';
import { modelFixture } from './model-fixtures.mjs';
import { readMdlDoc, writeMdlDoc } from './vendor/mdl-codec.mjs';

const section=bytes=>readMdlDoc(bytes).sections.find(s=>s.type==='MDLA');
const events=bytes=>section(bytes).anims[0].events;
const change=fn=>{const doc=readMdlDoc(modelFixture());fn(doc.sections.find(s=>s.type==='MDLA').anims[0],doc);return writeMdlDoc(doc);};
function rejectsUnchanged(bytes,operation,pattern){const before=bytes.slice();assert.throws(()=>editFrameEvents(bytes,operation),pattern);assert.deepEqual(bytes,before);}
test('inspection exposes owned event descriptions and canonical encoded timing',()=>{
 const bytes=modelFixture(),before=bytes.slice(),result=inspectFrameEvents(bytes,7);
 assert.deepEqual(result,{clip:7,frameCount:2,fps:2,events:[{index:0,frame:1,name:'middle',time:0.5,raw:'{"frame":1,"name":"middle","future":{"kept":true}}'}]});
 result.events[0].name='changed';assert.deepEqual(bytes,before);assert.equal(inspectFrameEvents(bytes,7).events[0].name,'middle');
});
test('add uses inclusive endpoints and exact Float32 time, permits empty and long Unicode names',()=>{
 let bytes=change(clip=>{clip.fps=3;clip.events[0].time=Math.fround(1/3);});
 for(const [frame,name] of [[0,''],[2,'🌟'.repeat(100)]])bytes=editFrameEvents(bytes,{type:'add',clip:7,frame,name});
 assert.equal(events(bytes)[2].time,Math.fround(2/3));assert.deepEqual(inspectFrameEvents(bytes,7).events.map(e=>[e.frame,e.name]),[[1,'middle'],[0,''],[2,'🌟'.repeat(100)]]);
});
test('update patches only changed spans and no-op bytes preserve spelling',()=>{
 const raw=' {"fr\\u0061me":1.0,"name":"mi\\u0064dle","x":900719925474099312345,"x":[{"name":"nested"}]} ';
 const bytes=change(clip=>{clip.events[0].json=raw;});
 assert.deepEqual(editFrameEvents(bytes,{type:'update',clip:7,index:0,frame:1,name:'middle'}),bytes);
 const updated=editFrameEvents(bytes,{type:'update',clip:7,index:0,frame:2,name:'fire'});
 assert.equal(events(updated)[0].json,raw.replace(':1.0',':2').replace('"mi\\u0064dle"','"fire"'));assert.equal(events(updated)[0].time,1);
 const named=editFrameEvents(bytes,{type:'update',clip:7,index:0,name:'fire'});assert.equal(events(named)[0].time,0.5);
});
test('a semantic no-op and name-only update preserve the original encoded signed-zero time',()=>{
 const bytes=change(clip=>{clip.events[0]={time:-0,json:'{"frame":0,"name":"zero"}'};});
 assert.deepEqual(editFrameEvents(bytes,{type:'update',clip:7,index:0}),bytes);
 const updated=editFrameEvents(bytes,{type:'update',clip:7,index:0,name:'renamed'});
 assert.ok(Object.is(events(updated)[0].time,-0));
});
test('duplicate is exact and same-frame stable order follows move destination indices',()=>{
 const source=modelFixture(),duplicated=editFrameEvents(source,{type:'duplicate',clip:7,index:0});
 assert.deepEqual(events(duplicated),[events(source)[0],events(source)[0]]);
 let bytes=editFrameEvents(duplicated,{type:'update',clip:7,index:1,name:'second'});
 bytes=editFrameEvents(bytes,{type:'add',clip:7,frame:1,name:'third'});
 bytes=editFrameEvents(bytes,{type:'move',clip:7,index:0,to:2});assert.deepEqual(inspectFrameEvents(bytes,7).events.map(e=>e.name),['second','third','middle']);
 bytes=editFrameEvents(bytes,{type:'move',clip:7,index:2,to:0});assert.deepEqual(inspectFrameEvents(bytes,7).events.map(e=>e.name),['middle','second','third']);
 assert.deepEqual(editFrameEvents(bytes,{type:'move',clip:7,index:1,to:1}),bytes);
 assert.deepEqual(events(editFrameEvents(bytes,{type:'remove',clip:7,index:1})).map(e=>JSON.parse(e.json).name),['middle','third']);
});
test('read-only opaque records remain exact through explicit duplicate, reorder and removal',()=>{
 for(const raw of ['{"frame":"1","name":"string"}','{"frame":0,"frame":1,"name":"duplicate"}','{"frame":1,"name":"a","n\\u0061me":"b"}','{"frame":1}','{"frame":1,"name":"\\ud800"}']){
  const bytes=change(clip=>{clip.events[0].json=raw;}),entry=inspectFrameEvents(bytes,7).events[0];
  assert.ok(entry.reason);assert.equal(entry.raw,raw);assert.equal(entry.frame,undefined);assert.equal(entry.name,undefined);
  rejectsUnchanged(bytes,{type:'update',clip:7,index:0,name:'fire'},/event|name|frame/i);
  const duplicate=editFrameEvents(bytes,{type:'duplicate',clip:7,index:0});assert.deepEqual(events(duplicate),[events(bytes)[0],events(bytes)[0]]);
  assert.deepEqual(editFrameEvents(duplicate,{type:'move',clip:7,index:0,to:1}),duplicate);
  assert.deepEqual(editFrameEvents(duplicate,{type:'remove',clip:7,index:0}),bytes);
 }
 const bytes=change(clip=>{clip.events[0].time=0.75;});assert.match(inspectFrameEvents(bytes,7).events[0].reason,/time/i);
});
test('edits preserve other clips, tracks, bind data and opaque sections exactly',()=>{
 const bytes=change((clip,doc)=>{doc.sections.find(s=>s.type==='MDLA').anims.push({...clip,id:8});});
 const updated=editFrameEvents(bytes,{type:'add',clip:7,frame:2,name:'end'}),before=readMdlDoc(bytes),after=readMdlDoc(updated);
 assert.deepEqual(section(updated).anims[1],section(bytes).anims[1]);
 assert.deepEqual({...section(updated).anims[0],events:events(bytes)},section(bytes).anims[0]);
 assert.deepEqual(after.sections.filter(s=>s.type!=='MDLA'),before.sections.filter(s=>s.type!=='MDLA'));
 updated.fill(0);assert.notEqual(bytes[0],0);
});
test('invalid operations, frame/name/index and clip identifiers fail without source mutation',()=>{
 const bytes=modelFixture();
 for(const operation of [null,{}, {type:'delete',clip:7,index:0},{type:'add',clip:8,frame:0,name:'x'},{type:'add',clip:'7',frame:0,name:'x'},{type:'add',clip:7,frame:-1,name:'x'},{type:'add',clip:7,frame:3,name:'x'},{type:'add',clip:7,frame:0.5,name:'x'},{type:'add',clip:7,frame:0,name:'\ud800'},{type:'add',clip:7,frame:0,name:'a\0b'},{type:'add',clip:7,frame:0},{type:'update',clip:7,index:0,name:null},{type:'update',clip:7,index:0,frame:null},{type:'remove',clip:7},{type:'remove',clip:7,index:-1},{type:'duplicate',clip:7,index:1},{type:'move',clip:7,index:0,to:1},{type:'move',clip:7,index:0,to:0.5}])rejectsUnchanged(bytes,operation);
 assert.throws(()=>inspectFrameEvents(bytes,8),/clip|animation/i);
});
test('codec actual 4096 event limit is enforced with no smaller authoring cap',()=>{
 const bytes=change(clip=>{clip.events=Array.from({length:4096},()=>({...clip.events[0]}));});assert.equal(inspectFrameEvents(bytes,7).events.length,4096);
 rejectsUnchanged(bytes,{type:'add',clip:7,frame:1,name:'overflow'},/4096/);rejectsUnchanged(bytes,{type:'duplicate',clip:7,index:0},/4096/);
 const fewer=editFrameEvents(bytes,{type:'remove',clip:7,index:0});assert.equal(events(editFrameEvents(fewer,{type:'add',clip:7,frame:1,name:'at limit'})).length,4096);
});
