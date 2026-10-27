import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createPropertyCatalog} from '../Sources/WallpaperApp/Resources/SceneRuntime/scene-properties.mjs';

if(process.argv.length!==3)throw new Error('Pass the actual Core XCTest catalog artifact path');
const fixtureRoot=new URL('../Tests/Fixtures/ScenePropertyCatalog/',import.meta.url);
const index=JSON.parse(await readFile(new URL('cases.json',fixtureRoot)));
const fixtures=await Promise.all(index.map(async({id,file})=>({id,project:JSON.parse(await readFile(new URL(file,fixtureRoot)))})));
const native=JSON.parse(await readFile(process.argv[2]));
const kinds=new Set(['bool','slider','color','textinput','combo']);
const number=value=>typeof value==='number'&&Number.isFinite(value)?value:null;
const scalar=value=>typeof value==='boolean'||typeof value==='string'||number(value)!==null?value:null;
const choices=value=>Array.isArray(value)&&value.length&&value.every(item=>item&&typeof item.label==='string'&&typeof item.value==='string')?value.map(({label,value})=>({label,value})):[];
const expected=fixtures.map(({id,project})=>{
 try{return{id,failed:false,rows:createPropertyCatalog(project).map(row=>({name:row.name,label:typeof row.text==='string'?row.text:row.name,
  kind:kinds.has(row.type)?row.type:null,defaultValue:scalar(row.value),minimum:number(row.min),maximum:number(row.max),step:number(row.step),order:number(row.order),
  options:choices(row.options),readOnlyReason:row.readOnlyReason??null}))};}
 catch{return{id,failed:true,rows:[]};}
});
// Swift's synthesized optional fields are omitted; normalize only the transport
// shape, preserving every authored string and every ordered row/choice.
for(const result of native)for(const row of result.rows)for(const key of ['kind','defaultValue','minimum','maximum','step','order','readOnlyReason'])row[key]??=null;
assert.deepEqual(native,expected,'Native property catalog differs from the shared actual JavaScript catalog');
console.log(`Core/shared-JavaScript property catalog parity: ${fixtures.length} real fixture cases passed`);
