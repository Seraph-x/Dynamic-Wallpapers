import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectMixLayers,editMixLayers,assertMixTable } from './model-mixing.mjs';
const clips=[{id:7,name:'Base'},{id:11,name:'Overlay'}];
const table=()=>[{animation:7,future:{kept:['exact']}},{name:'Overlay',animation:11,blend:.5,rate:2,visible:false,additive:true}];
function rejects(value,operation){const before=structuredClone(value);assert.throws(()=>editMixLayers(value,operation,clips));assert.deepEqual(value,before);}
test('inspection retains default representations and exposes effective native fields without edits',()=>{
 for(const value of [undefined,null,[]])assert.deepEqual(inspectMixLayers(value,clips),{default:true,rows:[]});
 const value=table(),before=structuredClone(value),info=inspectMixLayers(value,clips);assert.equal(info.default,false);assert.deepEqual(info.rows[0].values,{name:'',animation:7,blend:1,rate:1,visible:true,additive:false});assert.equal(info.rows[0].reason,undefined);info.rows[0].values.name='owned';assert.deepEqual(value,before);
});
test('new layer appends chosen native clip; a duplicate owns all unknown fields',()=>{
 const value=table(),added=editMixLayers(value,{type:'add',clip:11,name:'New'},clips);assert.deepEqual(added.at(-1),{name:'New',animation:11,blend:1,rate:1,visible:true,additive:false});
 const copy=editMixLayers(value,{type:'duplicate',index:0},clips);assert.deepEqual(copy[1],value[0]);copy[1].future.kept.push('owned');assert.deepEqual(value,table());
});
test('no-op update keeps optional fields absent and original JSON unchanged',()=>{
 const value=table(),next=editMixLayers(value,{type:'update',index:0,values:{name:'',animation:7,blend:1,rate:1,visible:true,additive:false}},clips);assert.deepEqual(next,value);
});
test('known field updates preserve unrelated entries and future metadata exactly',()=>{
 const value=table(),next=editMixLayers(value,{type:'update',index:0,values:{name:'Same model',animation:11,blend:.25,rate:-2,visible:false,additive:true}},clips);
 assert.deepEqual(next,[{...value[0],name:'Same model',animation:11,blend:.25,rate:-2,visible:false,additive:true},value[1]]);assert.deepEqual(value,table());
});
test('moving changes only order; removal can deliberately leave an empty default stack',()=>{
 const value=table();assert.deepEqual(editMixLayers(value,{type:'move',index:1,to:0},clips),[value[1],value[0]]);
 const next=editMixLayers(value,{type:'remove',index:1},clips);assert.deepEqual(next,[value[0]]);assert.deepEqual(editMixLayers(next,{type:'remove',index:0},clips),[]);
});
test('finite native extrapolation weights and stopped/reverse rates are not clamped',()=>{
 for(const blend of [-2,0,2])for(const rate of [-3,0,3]){const next=editMixLayers(table(),{type:'update',index:0,values:{blend,rate}},clips);assert.equal(next[0].blend,blend);if(rate!==1)assert.equal(next[0].rate,rate);}
});
test('controlled rows remain readable and exact while independent constant rows can change',()=>{
 for(const field of ['name','blend','rate','visible','additive']){const value=table();value[0][field]={value:1,script:'return userProperties.value;',future:17};const before=structuredClone(value),info=inspectMixLayers(value,clips);assert.match(info.rows[0].reason,/controlled|unsupported/i);rejects(value,{type:'update',index:0,values:{name:'overwrite'}});rejects(value,{type:'duplicate',index:0});
  const next=editMixLayers(value,{type:'update',index:1,values:{blend:.75}},clips);assert.deepEqual(next[0],value[0]);assert.deepEqual(value,before);assert.deepEqual(editMixLayers(value,{type:'remove',index:0},clips),[value[1]]);
 }
});
test('unavailable clip is shown explicitly and retained through unrelated editing',()=>{
 const value=table();value[0].animation=99;assert.match(inspectMixLayers(value,clips).rows[0].reason,/unavailable|missing/i);assert.deepEqual(editMixLayers(value,{type:'update',index:1,values:{blend:.75}},clips)[0],value[0]);rejects(value,{type:'duplicate',index:0});
});
test('malformed whole table stays visibly read-only and cannot become default on edit',()=>{
 for(const value of [{script:'whole'},'7',[{}],[7],[{animation:'7'}],[{animation:-1}]]){const info=inspectMixLayers(value,clips);assert(info.error);assert.equal(info.default,false);rejects(value,{type:'add',clip:7});assert.throws(()=>assertMixTable(value));}
});
test('invalid values, indices and clip IDs fail without modifying source content',()=>{
 for(const values of [{blend:NaN},{blend:Infinity},{blend:'1'},{rate:-Infinity},{name:7},{visible:0},{additive:'false'},{animation:99},{animation:-1},{animation:1.5},{name:null},{future:'overwritten'}])rejects(table(),{type:'update',index:0,values});
 for(const operation of [null,{}, {type:'unknown',index:0},{type:'add',clip:99},{type:'remove',index:-1},{type:'move',index:0,to:2},{type:'move',index:1,to:.5},{type:'duplicate',index:2},{type:'update',index:0,values:null}])rejects(table(),operation);
});
