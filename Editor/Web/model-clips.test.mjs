import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectClips, editModelClips } from './model-clips.mjs';
import { modelFixture } from './model-fixtures.mjs';
import { readMdlDoc, writeMdlDoc } from './vendor/mdl-codec.mjs';
import { restMatrix, restPose } from './model-math.mjs';

const animation = bytes => readMdlDoc(bytes).sections.find(s=>s.type==='MDLA');
const change = fn => {const doc=readMdlDoc(modelFixture());fn(doc,doc.sections.find(s=>s.type==='MDLA'));return writeMdlDoc(doc);};
const create = {type:'create',name:'Rest',fps:30,frameCount:4,mode:'loop'};
function rejectsUnchanged(bytes,operation,pattern) {const before=bytes.slice();assert.throws(()=>editModelClips(bytes,operation),pattern);assert.deepEqual(bytes,before);}

test('inspection exposes encoded timing and first default without editing input',()=>{
 const bytes=modelFixture(),before=bytes.slice();assert.deepEqual(inspectClips(bytes),{defaultId:7,clips:[{id:7,name:'Move right',fps:2,frameCount:2,mode:'mirror',duration:1}]});assert.deepEqual(bytes,before);
});
test('create uses actual local bind transforms even when source frame zero differs',()=>{
 const bytes=change(doc=>{doc.sections.find(s=>s.type==='MDLS').bones[2].matrix=restMatrix([35,13,0,0,0,0.4,1,1,1]);});
 const result=editModelClips(bytes,create),doc=readMdlDoc(result.bytes),clip=animation(result.bytes).anims.at(-1);
 assert.notEqual(result.id,7);assert.equal(clip.id,result.id);assert.deepEqual(clip.events,[]);
 for(const [bone,index] of doc.sections.find(s=>s.type==='MDLS').bones.entries())for(let f=0;f<=4;f++)assert.deepEqual(Array.from(clip.tracks[bone].data.subarray(f*9,f*9+9)),Array.from(restPose(index.matrix)));
 assert.deepEqual(animation(result.bytes).anims[0],animation(bytes).anims[0]);
 for(const section of doc.sections.filter(s=>s.type!=='MDLA'))assert.deepEqual(section,readMdlDoc(bytes).sections.find(s=>s.type===section.type));
});
test('create works with absent and empty MDLA; deleting last leaves readable empty MDLA',()=>{
 for(const absent of [true,false]){const bytes=change((doc,section)=>{if(absent)doc.sections=doc.sections.filter(s=>s!==section);else section.anims=[];});
  assert.deepEqual(inspectClips(bytes),{clips:[],defaultId:null});const made=editModelClips(bytes,create),removed=editModelClips(made.bytes,{type:'delete',id:made.id,referenced:[]});assert.deepEqual(animation(removed.bytes).anims,[]);assert.equal(inspectClips(removed.bytes).defaultId,null);
 }
});
test('duplicate preserves exact tracks, opaque events, metadata and chooses a unique u32',()=>{
 const bytes=change((doc,s)=>{s.anims[0].unk1=91;s.anims[0].tracks[1].boneId=44;s.anims[0].id=0xffffffff;});
 const result=editModelClips(bytes,{type:'duplicate',id:0xffffffff,name:'Copy'}),[source,copy]=animation(result.bytes).anims;
 assert.ok(Number.isInteger(result.id)&&result.id>=0&&result.id<=0xffffffff);assert.notEqual(result.id,source.id);assert.deepEqual({...copy,id:source.id,name:source.name},source);
});
test('name-only edit preserves opaque event metadata and unrelated motion exactly',()=>{
 const bytes=change((doc,s)=>{s.anims[0].events[0].json='{"frame":"1","unknown":true}';});
 const result=editModelClips(bytes,{type:'update',id:7,name:'Full name'}),old=animation(bytes).anims[0],updated=animation(result.bytes).anims[0];assert.deepEqual({...updated,name:old.name},old);
});
test('FPS changes speed at fixed samples and recomputes seconds without changing event JSON',()=>{
 const bytes=modelFixture(),result=editModelClips(bytes,{type:'update',id:7,fps:4}),old=animation(bytes).anims[0],updated=animation(result.bytes).anims[0];
 assert.equal(inspectClips(result.bytes).clips[0].duration,0.5);assert.equal(updated.events[0].time,0.25);assert.equal(updated.events[0].json,old.events[0].json);assert.deepEqual(updated.tracks,old.tracks);
});
test('normalized resize samples moving tracks, retains endpoints and uses shortest Euler path',()=>{
 const bytes=change((doc,s)=>{const track=s.anims[0].tracks[2].data;track[5]=3;track[14]=-3;track[23]=-2.5;});
 const result=editModelClips(bytes,{type:'update',id:7,frameCount:4}),old=animation(bytes).anims[0],updated=animation(result.bytes).anims[0],data=updated.tracks[2].data;
 assert.equal(data[9+1],15);assert.ok(Math.abs(data[9+5]-Math.PI)<1e-6);assert.deepEqual(data.subarray(0,9),old.tracks[2].data.subarray(0,9));assert.deepEqual(data.subarray(36),old.tracks[2].data.subarray(18));assert.deepEqual(updated.events,old.events);
});
test('delete any unreferenced clip; first of many requires explicit replacement and reorders only it',()=>{
 let bytes=modelFixture();const a=editModelClips(bytes,{type:'duplicate',id:7,name:'Second'});const b=editModelClips(a.bytes,{type:'duplicate',id:7,name:'Third'});bytes=b.bytes;
 rejectsUnchanged(bytes,{type:'delete',id:7,referenced:[]},/replacement/i);
 const result=editModelClips(bytes,{type:'delete',id:7,replacement:b.id,referenced:[]});assert.deepEqual(inspectClips(result.bytes).clips.map(c=>c.id),[b.id,a.id]);
 assert.deepEqual(inspectClips(editModelClips(bytes,{type:'delete',id:a.id,referenced:[]}).bytes).clips.map(c=>c.id),[7,b.id]);
 rejectsUnchanged(bytes,{type:'delete',id:7,replacement:7,referenced:[]},/replacement/i);rejectsUnchanged(bytes,{type:'delete',id:a.id,referenced:[a.id]},/referenc/i);
});
test('reject unsupported and malformed resources without modifying input',()=>{
 const variants=[change((d,s)=>{s.anims[0].tracks.pop();}),change((d,s)=>{s.anims[0].tracks[0].data[0]=NaN;}),change((d,s)=>{s.anims.push({...s.anims[0]});}),change((d,s)=>{s.version='0005';}),change(d=>{d.trailing=Uint8Array.of(1);}),change(d=>{d.sections.find(s=>s.type==='MDLS').bones[1].parent=1;})];
 for(const bytes of variants)rejectsUnchanged(bytes,create);
});
test('new headers obey actual pinned reader bounds and reject nonfinite timing',()=>{
 for(const properties of [{name:''},{name:'x'.repeat(65)},{name:'\ud800'},{name:'bad\0name'},{name:null},{fps:'4'},{fps:241},{fps:0},{fps:1e-50},{fps:NaN},{frameCount:0},{frameCount:1.5},{frameCount:100001},{mode:'invalid'}])rejectsUnchanged(modelFixture(),{...create,...properties});
});
test('duplicate count is constrained by the pinned reader 256-header limit',()=>{
 const bytes=change((doc,s)=>{const source=s.anims[0];s.anims=Array.from({length:256},(_,i)=>({...source,id:i}));});rejectsUnchanged(bytes,{type:'duplicate',id:0,name:'overflow'},/256/);
});
test('unchanged unusual source headers remain lossless but newly authored unsupported headers fail',()=>{
 const bytes=change((d,s)=>{s.anims[0].name='x'.repeat(65);});const result=editModelClips(bytes,{type:'update',id:7,mode:'single'});assert.equal(animation(result.bytes).anims[0].name,'x'.repeat(65));
 rejectsUnchanged(bytes,{type:'duplicate',id:7,name:'x'.repeat(65)},/name/i);
});
test('timing edits require readable frame/name, consistent encoded time and preserve opaque JSON',()=>{
 const variants=['{"frame":"1","name":"middle"}','{"frame":1}','{"frame":3,"name":"outside"}'];
 for(const json of variants){const bytes=change((d,s)=>{s.anims[0].events[0].json=json;});rejectsUnchanged(bytes,{type:'update',id:7,fps:3},/event/i);}
 const inconsistent=change((d,s)=>{s.anims[0].events[0].time=0.75;});rejectsUnchanged(inconsistent,{type:'update',id:7,fps:3},/event/i);
 const excluded=change((d,s)=>{s.anims[0].events[0]={time:1,json:'{"frame":2,"name":"end","unknown":9}'};});rejectsUnchanged(excluded,{type:'update',id:7,frameCount:1},/event/i);
});
test('invalid bind transforms and overflowing sampled world transforms fail observably',()=>{
 const badBind=change(d=>{d.sections.find(s=>s.type==='MDLS').bones[0].matrix[0]=0;});rejectsUnchanged(badBind,create);
 const overflow=change((d,s)=>{for(const t of s.anims[0].tracks)for(let f=0;f<3;f++)t.data[f*9+6]=1e20;});rejectsUnchanged(overflow,{type:'update',id:7,frameCount:4});
});
test('no-op editing is byte exact; Unicode full names survive inspection',()=>{
 const bytes=modelFixture();assert.deepEqual(editModelClips(bytes,{type:'update',id:7}).bytes,bytes);
 const name='\ufeff静止动画 🌟';const result=editModelClips(bytes,{type:'update',id:7,name});assert.equal(inspectClips(result.bytes).clips[0].name,name);
});
test('a raw animation section or nonstandard table cannot be edited',()=>{
 const variants=[change((d,s)=>{s.raw=Uint8Array.of(1,2,3);}),change((d,s)=>{s.anims[0].prefix[5]=1;}),change(d=>{d.sections.find(s=>s.type==='MDLS').tail[0]=1;})];
 for(const bytes of variants)rejectsUnchanged(bytes,create,/Unsupported/i);
});
test('deletion requires an explicit readable reference table and validates its values',()=>{
 for(const referenced of [undefined,null,{},['7'],[-1],[0x100000000]])rejectsUnchanged(modelFixture(),{type:'delete',id:7,referenced},/referenc/i);
 rejectsUnchanged(modelFixture(),{type:'delete',id:7,replacement:7,referenced:[]},/replacement/i);
});
test('invalid operations and IDs leave bytes intact',()=>{
 for(const operation of [null,{}, {type:'nonsense',id:7},{type:'update',id:8},{type:'update',id:-1},{type:'duplicate',id:7},{type:'update',id:7,fps:null}])rejectsUnchanged(modelFixture(),operation);
});
test('resizing a multi-turn Euler track samples the pinned renderer’s single-wrap interpolation',()=>{
 const source=change((d,s)=>{const a=s.anims[0];a.frameCount=1;a.events=[];for(const track of a.tracks)track.data=Float32Array.from([...track.data.subarray(0,9),...track.data.subarray(18,27)]);a.tracks[2].data[5]=0;a.tracks[2].data[14]=Math.fround(4*Math.PI);});
 const input=animation(source).anims[0].tracks[2].data[14],result=animation(editModelClips(source,{type:'update',id:7,frameCount:2}).bytes).anims[0];assert(Math.abs(result.tracks[2].data[14]-(input-2*Math.PI)/2)<1e-6);
});
