import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {openScriptPlayback} from './script-migration-fixture.mjs';
import {bindingDocument} from './property-bindings-fixture.mjs';
import {SceneDocument} from './document.mjs';
import {inspectPropertyBinding} from './property-bindings.mjs';

const h=await openEditorHarness({version:1,session:'binding-runtime',generation:1,language:'en',document:bindingDocument});
async function start(document){const page=await openScriptPlayback(h.page,document,new Map());await page.evaluate(()=>{document.documentElement.style.background='#000';document.body.style.background='#000';});await page.waitForFunction(()=>globalThis.__bindingTextProbe);return page;}
async function pixels(page,expected){
 const end=Date.now()+4000;let actual;
 do{
  const image=await page.locator('#scene canvas').screenshot();
  actual=await page.evaluate(async bytes=>{const bitmap=await createImageBitmap(new Blob([new Uint8Array(bytes)],{type:'image/png'})),canvas=document.createElement('canvas');canvas.width=bitmap.width;canvas.height=bitmap.height;const ctx=canvas.getContext('2d');ctx.drawImage(bitmap,0,0);bitmap.close();return [120,320].map(x=>[...ctx.getImageData(x-5,175,10,10).data]);},[...image]);
  if(actual.every((region,index)=>region.every((value,offset)=>offset%4===3||Math.abs(value-expected[index][offset%4])<16)))return;
 }while(Date.now()<end);
 assert.fail('Actual binding GPU pixels differ: '+JSON.stringify(actual.map(region=>region.slice(0,4)))+' expected '+JSON.stringify(expected));
}
const black=[0,0,0],red=[255,0,0],green=[0,255,0];
try{
 const expected=JSON.parse(await readFile(path.join(h.artifactRoot,'bindings-expected.json'),'utf8'));
 const actual=await start(expected);
 try{
  await pixels(actual,[black,black]);assert.deepEqual(await actual.evaluate(()=>globalThis.__bindingTextProbe),{text:'Authored 雪',pointsize:40});
  await actual.evaluate(()=>globalThis.__migrationPlayback.setProperties({enabled:true,opacity:1,tint:'1 0 0',mode:'night',caption:'temporary',fontSize:48}));
  await pixels(actual,[red,green]);assert.deepEqual(await actual.evaluate(()=>globalThis.__bindingTextProbe),{text:'Authored 雪',pointsize:40},'Pinned load-time text binding capability changed');
  await actual.evaluate(()=>globalThis.__migrationPlayback.setProperties({mode:'day'}));await pixels(actual,[red,black]);
  assert.deepEqual(await actual.evaluate(()=>globalThis.__playbackErrors),[]);
 }finally{await actual.close();}
 // The original renderer compares integer-shaped choices numerically. Keep
 // exact stored identifiers/conditions while proving that actual behavior.
 const numericDoc=new SceneDocument(expected);numericDoc.bindProperty({type:'bind',layerId:2,field:'visible',name:'numeric',condition:'01',replace:true});
 const numeric=await start(numericDoc.snapshot());
 try{
  await pixels(numeric,[black,green]);await numeric.evaluate(()=>globalThis.__migrationPlayback.setProperties({numeric:'1'}));await pixels(numeric,[black,green]);
  await numeric.evaluate(()=>globalThis.__migrationPlayback.setProperties({numeric:'2'}));await pixels(numeric,[black,black]);
 }finally{await numeric.close();}
 const numericBase=structuredClone(expected);numericBase.scene.objects[2].text='123';
 assert(inspectPropertyBinding(numericBase,{layerId:3,field:'text'}).choices.find(row=>row.name==='caption').incompatible);
 assert.throws(()=>new SceneDocument(numericBase).bindProperty({type:'bind',layerId:3,field:'text',name:'caption'}),/shape/);
 // Deliberately hand-authored unsupported input tests the pin's boundary,
 // independent of the Editor's compatibility implementation.
 numericBase.scene.objects[2].text={value:'123',user:'caption'};
 const rejectedShape=await start(numericBase);
 try{assert.equal(await rejectedShape.evaluate(()=>globalThis.__bindingTextProbe.text),'123');}finally{await rejectedShape.close();}
 const numericDefault=structuredClone(expected);numericDefault.project.general.properties.caption.value='123';
 const acceptedShape=await start(numericDefault);
 try{assert.equal(await acceptedShape.evaluate(()=>globalThis.__bindingTextProbe.text),'123');}finally{await acceptedShape.close();}
 const removed=new SceneDocument(expected);
 for(const [layerId,field]of [[1,'color'],[1,'alpha'],[1,'visible'],[2,'visible'],[3,'text'],[3,'pointsize']])removed.bindProperty({type:'remove',layerId,field});
 assert.deepEqual(removed.snapshot(),bindingDocument);
 const restored=await start(removed.snapshot());
 try{await pixels(restored,[green,green]);assert.deepEqual(await restored.evaluate(()=>globalThis.__bindingTextProbe),{text:'Original\r\n雪',pointsize:24});await restored.evaluate(()=>globalThis.__migrationPlayback.setProperties({enabled:false,tint:'0 0 1',opacity:0,mode:'day'}));await pixels(restored,[green,green]);}finally{await restored.close();}
 console.log('Binding runtime: real default/live GPU output, numeric choice equality, exact numeric-text shape boundary, load-time text/size limits and removed-binding literal restoration passed');
}finally{await h.close();}
