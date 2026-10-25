import test from 'node:test';
import assert from 'node:assert/strict';
import * as api from './model-api-entry.mjs';
import { modelFixture } from './model-fixtures.mjs';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { editModelClips } from './model-clips.mjs';
import { editBonePose } from './model-poses.mjs';
import { bakeBoneDelta } from './model-fk.mjs';
import { editModelHierarchy } from './model-hierarchy.mjs';
import { bakeTwoBoneIk } from './model-ik.mjs';
import { ikFixture } from './model-ik-fixture.mjs';
const inspect=(bytes,more={})=>api.inspectBoneKeys(bytes,{clip:7,bone:2,frame:1,...more});
const edit=(bytes,type,more={})=>api.editBoneKeys(bytes,{type,clip:7,bone:2,...more});
const doc=bytes=>readMdlDoc(bytes);
const bones=bytes=>doc(bytes).sections.find(s=>s.type==='MDLS').bones;
const clip=bytes=>doc(bytes).sections.find(s=>s.type==='MDLA').anims[0];
const change=(fn,bytes=modelFixture())=>{const d=doc(bytes);fn(d,d.sections.find(s=>s.type==='MDLA').anims[0],d.sections.find(s=>s.type==='MDLS').bones);return writeMdlDoc(d);};
const meta=(raw,bytes=modelFixture())=>change((d,c,b)=>{b[2].meta=raw;},bytes);
const map=(keys=[0,2],frameCount=2)=>`{"dynamicWallpaperBoneKeys":{"version":1,"clips":{"7":{"frameCount":${frameCount},"keys":${JSON.stringify(keys)}}}}}`;
const managed=()=>edit(edit(modelFixture(),'adopt'),'reduce');
const reject=(bytes,type,more={},pattern)=>{const before=bytes.slice();assert.throws(()=>edit(bytes,type,more),pattern);assert.deepEqual(bytes,before);};

test('sparse APIs are exported and inspect native samples without writing',()=>{
 assert.equal(typeof api.inspectBoneKeys,'function');assert.equal(typeof api.editBoneKeys,'function');
 const source=modelFixture(),before=source.slice();assert.deepEqual(inspect(source),{kind:'unmanaged',keys:[],frame:1,pose:[35,30,0,0,0,0,1,1,1],fps:2,frameCount:2});assert.deepEqual(source,before);
});
test('adoption captures every sample; reduction is metadata only and no-op operations byte exact',()=>{
 const source=modelFixture(),adopted=edit(source,'adopt');assert.deepEqual(inspect(adopted).keys,[0,1,2]);assert.deepEqual(clip(adopted),clip(source));
 assert.deepEqual(edit(adopted,'adopt'),adopted);assert.deepEqual(edit(adopted,'set',{frame:1,pose:inspect(adopted).pose}),adopted);
 const reduced=edit(adopted,'reduce');assert.deepEqual(inspect(reduced).keys,[0,2]);assert.deepEqual(clip(reduced),clip(source));assert.deepEqual(edit(reduced,'reduce'),reduced);
 assert.equal(bones(reduced)[2].meta,'{"future":"right","dynamicWallpaperBoneKeys":{"version":1,"clips":{"7":{"frameCount":2,"keys":[0,2]}}}}');
 assert.deepEqual(clip(edit(reduced,'forget')),clip(source));assert.equal(inspect(edit(reduced,'forget')).kind,'unmanaged');
});
test('set bakes an independently encoded full MDL and isolates bones, clips, events and opaque sections',()=>{
 const source=editModelClips(edit(managed(),'adopt',{bone:1}),{type:'duplicate',id:7,name:'Unrelated'}).bytes,pose=[35,120,0,0,0,0,1,1,1];const result=edit(source,'set',{frame:2,pose});
 const expected=change((d,c)=>{c.tracks[2].data[10]=60;c.tracks[2].data[19]=120;},source);
 assert.deepEqual(result,expected);assert.equal(inspect(result).kind,'managed');assert.deepEqual(inspect(result).pose,[35,60,0,0,0,0,1,1,1]);
});
test('add captures native pose, duplicate and move preserve pose, remove rebakes surviving anchors',()=>{
 let bytes=editModelClips(managed(),{type:'update',id:7,frameCount:4}).bytes;bytes=edit(bytes,'adopt');bytes=edit(bytes,'reduce');
 bytes=edit(bytes,'add',{frame:1});assert.deepEqual(inspect(bytes).keys,[0,1,4]);
 bytes=edit(bytes,'duplicate',{frame:1,to:2});assert.deepEqual(inspect(bytes,{frame:2}).pose,inspect(bytes,{frame:1}).pose);
 bytes=edit(bytes,'move',{frame:2,to:3});assert.deepEqual(inspect(bytes).keys,[0,1,3,4]);
 bytes=edit(bytes,'remove',{frame:1});assert.deepEqual(inspect(bytes).keys,[0,3,4]);
});
test('endpoints and selection validation reject collisions, invalid frames and operations immutably',()=>{
 const bytes=managed();for(const type of ['remove','move'])for(const frame of [0,2])reject(bytes,type,{frame,to:1},/endpoint|anchor/i);
 for(const [type,more] of [['add',{frame:0}],['set',{frame:1,pose:[1]}],['move',{frame:1,to:0}],['duplicate',{frame:0,to:2}],['add',{frame:0.5}],['add',{frame:3}],['nope',{}]])reject(bytes,type,more);
 assert.throws(()=>inspect(bytes,{clip:9}),/clip/i);assert.throws(()=>inspect(bytes,{bone:9}),/bone/i);assert.throws(()=>inspect(bytes,{frame:-1}),/frame/i);
 reject(modelFixture(),'set',{frame:0,pose:inspect(bytes).pose},/adopt|managed/i);
});
test('pose validation checks finite Float32, singular scales and all interpolated transforms',()=>{
 const bytes=managed();for(const value of [NaN,Infinity,1e100,1e-100]){const pose=inspect(bytes,{frame:2}).pose;pose[0]=value;reject(bytes,'set',{frame:2,pose});}
 const zero=inspect(bytes,{frame:2}).pose;zero[6]=0;reject(bytes,'set',{frame:2,pose:zero},/singular|scale|invertible/i);
 const negative=inspect(bytes,{frame:2}).pose;negative[6]=-1;reject(bytes,'set',{frame:2,pose:negative},/singular|scale|invertible/i);
 const overflow=change((d,c)=>{for(const t of c.tracks)for(let f=0;f<=2;f++)t.data[f*9+6]=1e20;},bytes);reject(overflow,'set',{frame:2,pose:inspect(overflow,{frame:2}).pose});
});
test('native Euler interpolation wraps only once, preserves exact raw endpoint and signed zero',()=>{
 const source=meta(map(),change((d,c)=>{c.tracks[2].data[5]=0;c.tracks[2].data[14]=Math.fround((Math.fround(4*Math.PI)-2*Math.PI)/2);c.tracks[2].data[23]=Math.fround(4*Math.PI);}));
 assert.equal(inspect(source).kind,'managed');assert.deepEqual(edit(source,'reduce'),source);
 const adopted=edit(change((d,c)=>{c.tracks[2].data[0]=-0;c.tracks[2].data[9]=0;c.tracks[2].data[18]=-0;}),'adopt');
 assert.deepEqual(inspect(edit(adopted,'reduce')).keys,[0,1,2]);assert.ok(Object.is(inspect(adopted,{frame:0}).pose[0],-0));
 const changed=edit(adopted,'set',{frame:1,pose:[-0,31,0,0,0,0,1,1,1]});assert.ok(Object.is(inspect(changed,{frame:0}).pose[0],-0));assert.ok(Object.is(inspect(changed,{frame:2}).pose[0],-0));
});
test('dense edits and duration changes expose stale maps requiring explicit adoption or forget',()=>{
 const bytes=managed(),dense=editBonePose(bytes,{type:'set',clip:7,bone:2,frame:1,pose:[35,33,0,0,0,0,1,1,1]});
 assert.equal(inspect(dense).kind,'stale');assert.match(inspect(dense).reason,/sample|dense/i);reject(dense,'add',{frame:1},/stale|sync/i);
 const adopted=edit(dense,'adopt');assert.deepEqual(inspect(adopted).keys,[0,1,2]);assert.deepEqual(clip(adopted),clip(dense));assert.equal(inspect(edit(dense,'forget')).kind,'unmanaged');
 const resized=editModelClips(bytes,{type:'update',id:7,frameCount:4}).bytes;assert.equal(inspect(resized).kind,'stale');assert.deepEqual(bones(resized)[2].meta,bones(bytes)[2].meta);
 const fk=bakeBoneDelta(bytes,{clip:7,bone:2,start:1,end:1,delta:[0,3,0,0,0,0,1,1,1]});assert.equal(inspect(fk).kind,'stale');
 const fps=editModelClips(bytes,{type:'update',id:7,fps:4,name:'New'}).bytes;assert.equal(inspect(fps).kind,'managed');assert.deepEqual(inspect(fps).keys,[0,2]);
});
test('unsupported malformed/future/duplicate owned metadata is explicit and cannot be replaced',()=>{
 const variants=['[]','null','not JSON','{"dynamicWallpaperBoneKeys":{}}','{"dynamicWallpaperBoneKeys":{"version":2,"clips":{}}}','{"dynamicWallpaperBoneKeys":{},"dynamicWallpaperBoneKeys":{}}','{"dynamicWallpaperBoneKeys":{"version":1,"version":1,"clips":{}}}','{"dynamicWallpaperBoneKeys":{"version":1,"clips":{"7":{"frameCount":2,"keys":[0,2],"keys":[0,2]}}}}',map([0,0,2]),map([1,2]),map([0,3])];
 for(const raw of variants){const bytes=meta(raw);assert.equal(inspect(bytes).kind,'unsupported',raw);assert.ok(inspect(bytes).reason);reject(bytes,'adopt',{},/metadata|keys|version|object|JSON|Duplicate/i);reject(bytes,'forget');}
 for(const raw of ['', '  ', '{}'])assert.equal(inspect(edit(meta(raw),'adopt')).kind,'managed');
});
test('span patches preserve unknown duplicate fields, giant lexemes and all other clip records',()=>{
 const raw=' { "x":900719925474099312345, "x":1e+99, "dynamicWallpaperBoneKeys" : { "version":1, "unknown":1e+100, "clips" : { "99":{"frameCount":3,"keys":[0,3],"u":9007199254740993999}, "7" : { "frameCount":2, "keys":[0,1,2], "future":9007199254740993999,"future":true } } } } ';
 const reduced=edit(meta(raw),'reduce'),expected=raw.replace('"keys":[0,1,2]','"keys":[0,2]');assert.equal(bones(reduced)[2].meta,expected);
 const forgotten=edit(reduced,'forget');assert.ok(bones(forgotten)[2].meta.includes('"99":{"frameCount":3,"keys":[0,3],"u":9007199254740993999}'));assert.ok(bones(forgotten)[2].meta.includes('"x":900719925474099312345, "x":1e+99'));assert.equal(inspect(forgotten).kind,'unmanaged');
});
test('clip duplicate copies recognized raw record, delete removes it, create clears reused orphan ID',()=>{
 const bytes=managed(),duplicated=editModelClips(bytes,{type:'duplicate',id:7,name:'Copy'});assert.equal(api.inspectBoneKeys(duplicated.bytes,{clip:duplicated.id,bone:2,frame:1}).kind,'managed');
 const removed=editModelClips(duplicated.bytes,{type:'delete',id:duplicated.id,referenced:[]}).bytes;assert.deepEqual(removed,bytes);
 const orphan=meta('{"dynamicWallpaperBoneKeys":{"version":1,"clips":{"1":{"frameCount":2,"keys":[0,2]}}}}');
 const created=editModelClips(orphan,{type:'create',name:'New',fps:2,frameCount:2,mode:'loop'});assert.equal(created.id,1);assert.equal(api.inspectBoneKeys(created.bytes,{clip:1,bone:2,frame:1}).kind,'unmanaged');
 for(const raw of ['not JSON','{"dynamicWallpaperBoneKeys":{"version":2,"clips":{}}}']){const source=meta(raw),copy=editModelClips(source,{type:'duplicate',id:7,name:'Copy'});assert.equal(bones(copy.bytes)[2].meta,raw);}
});
test('hierarchy reorder carries key metadata and selected track with the surviving bone',()=>{
 const bytes=managed(),result=editModelHierarchy(bytes,{type:'reparent',bone:1,parent:2,boneLimit:128}).bytes;assert.equal(bones(result)[1].name,'Right');assert.equal(inspect(result,{bone:1}).kind,'managed');assert.deepEqual(inspect(result,{bone:1}).pose,inspect(bytes).pose);
});
test('balanced reduction preserves irregular dense curves exactly and scales across many frames',()=>{
 const source=change((d,c)=>{c.frameCount=1024;c.events=[];for(const t of c.tracks){const pose=t.data.slice(0,9);t.data=new Float32Array(1025*9);for(let f=0;f<=1024;f++)t.data.set(pose,f*9);}for(let f=0;f<=1024;f++)c.tracks[2].data[f*9+1]=Math.fround(Math.sin(f/11)*100);});
 const reduced=edit(edit(source,'adopt'),'reduce');assert.equal(inspect(reduced).kind,'managed');assert.deepEqual(clip(reduced),clip(source));assert.ok(inspect(reduced).keys.length>2);
});

test('no-op set and reduce preserve noncanonical owned JSON value lexemes exactly',()=>{
 const source=meta(' {"dynamicWallpaperBoneKeys" : {"version":1e0,"clips":{"7":{"frameCount":2.0,"keys":[ 0 , 2 ],"extra":9007199254740993999}}}} ');
 assert.equal(inspect(source).kind,'managed');assert.deepEqual(edit(source,'reduce'),source);
 assert.deepEqual(edit(source,'set',{frame:2,pose:inspect(source,{frame:2}).pose}),source);
 const allSamples=meta(bones(source)[2].meta.replace('[ 0 , 2 ]','[ 0 , 1 , 2 ]'));assert.deepEqual(edit(allSamples,'adopt'),allSamples);
});

test('translation and scale use pinned weighted lerp rather than delta lerp cancellation',()=>{
 const source=change((d,c,b)=>{
  c.frameCount=3;c.events=[];
  for(const t of c.tracks){const first=t.data.slice(0,9);t.data=new Float32Array(36);for(let f=0;f<=3;f++)t.data.set(first,f*9);}
  const data=c.tracks[2].data;
  for(let f=0;f<=3;f++){const t=f/3;data[f*9]=f===0?1:f===3?-2:1*(1-t)+(-2)*t;}
  b[2].meta=map([0,3],3);
 });
 assert.equal(inspect(source).kind,'managed');assert.notEqual(inspect(source).pose[0],0);
 assert.deepEqual(edit(source,'reduce'),source);
 const pose=inspect(source,{frame:3}).pose;pose[0]=-5;
 const result=edit(source,'set',{frame:3,pose}),expected=change((d,c)=>{for(let f=1;f<=3;f++){const t=f/3;c.tracks[2].data[f*9]=f===3?-5:1*(1-t)+(-5)*t;}},source);
 assert.deepEqual(result,expected);
});

test('IK bakes expose staleness on affected ancestors and dense undo restores coherence',()=>{
 let source=ikFixture();
 for(const bone of [0,1]){source=edit(source,'adopt',{bone});source=edit(source,'reduce',{bone});}
 const baked=bakeTwoBoneIk(source,{clip:7,bone:2,start:1,end:1,target:[0,35,0],pole:[-35,35,0]}).bytes;
 for(const bone of [0,1])assert.equal(inspect(baked,{bone}).kind,'stale');
 assert.equal(inspect(baked).kind,'unmanaged');
 const restored=editBonePose(baked,{type:'set',clip:7,bone:0,frame:1,pose:inspect(source,{bone:0}).pose});
 assert.equal(inspect(restored,{bone:0}).kind,'managed');assert.equal(inspect(restored,{bone:1}).kind,'stale');
});
test('clip lifecycle copies raw stale records and replaces only a recognized orphan destination',()=>{
 const raw=' {"n":9007199254740993999,"dynamicWallpaperBoneKeys":{"version":1,"extra":1e99,"clips":{"7": {"frameCount":3.0,"keys":[ 0,3 ],"unknown":1e999,"unknown":false},"1":{"frameCount":2,"keys":[0,2]}}}} ';
 const source=meta(raw),copy=editModelClips(source,{type:'duplicate',id:7,name:'Copy'}),record=' {"frameCount":3.0,"keys":[ 0,3 ],"unknown":1e999,"unknown":false}';
 assert.equal(copy.id,1);assert.equal(bones(copy.bytes)[2].meta,raw.replace('"1":{"frameCount":2,"keys":[0,2]}','"1":'+record.trimStart()));
 assert.equal(api.inspectBoneKeys(copy.bytes,{clip:1,bone:2,frame:1}).kind,'stale');
 const removed=editModelClips(copy.bytes,{type:'delete',id:7,replacement:1,referenced:[]}).bytes;
 assert.ok(bones(removed)[2].meta.includes('"n":9007199254740993999'));assert.ok(bones(removed)[2].meta.includes('"1":'+record.trimStart()));
});
test('adding and rebaking keeps multi-turn Euler endpoint bits rather than wrapped reconstruction',()=>{
 const source=meta(map(),change((d,c)=>{c.tracks[2].data[23]=Math.fround(4*Math.PI);c.tracks[2].data[14]=Math.fround((c.tracks[2].data[23]-2*Math.PI)*.5);}));
 const added=edit(source,'add',{frame:1});assert.deepEqual(clip(added),clip(source));
 const pose=inspect(added,{frame:0}).pose;pose[1]=10;
 const changed=edit(added,'set',{frame:0,pose});assert.deepEqual(clip(changed).tracks[2].data.subarray(18,27),clip(source).tracks[2].data.subarray(18,27));
});

test('scale interpolation retains the pinned weighted lerp Float32 rounding',()=>{
 const source=change((d,c,b)=>{
  c.frameCount=7;c.events=[];
  for(const t of c.tracks){const first=t.data.slice(0,9);t.data=new Float32Array(72);for(let f=0;f<=7;f++)t.data.set(first,f*9);}
  for(let f=0;f<=7;f++){const t=f/7;c.tracks[2].data[f*9+6]=f===0?7845386.5:f===7?3170924.75:7845386.5*(1-t)+3170924.75*t;}
  b[2].meta=map([0,7],7);
 });
 assert.equal(inspect(source).kind,'managed');assert.equal(inspect(source).pose[6],7177606.5);assert.deepEqual(edit(source,'reduce'),source);
});


test('explicit adoption replaces a managed sparse map with every current sample',()=>{
 const source=managed(),before=source.slice(),adopted=edit(source,'adopt');
 assert.deepEqual(inspect(source).keys,[0,2]);assert.deepEqual(inspect(adopted).keys,[0,1,2]);
 assert.deepEqual(clip(adopted),clip(source));assert.deepEqual(source,before);
 assert.deepEqual(edit(adopted,'adopt'),adopted);
});
