import assert from 'node:assert/strict';
import { mkdir,readFile,writeFile,readdir } from 'node:fs/promises';
import path from 'node:path';
import { openEditorHarness } from './browser-editor-harness.mjs';
import { eventDocument,eventFixture,eventPaths } from './model-events-fixture.mjs';
import { solidPng } from './vendor/gltf-png.mjs';

const source=structuredClone(eventDocument);
source.title='Script contracts';
const wave='export function update(value){return Math.floor(engine.runtime*2)%2===0?{x:0,y:1,z:0}:{x:1,y:0,z:0};}';
const expected=structuredClone(source);expected.scene.objects[0].color.script=wave;
const blank={...structuredClone(source),scene:{...structuredClone(source.scene),objects:[]}};
const configuration={version:1,session:'script-contracts-test',generation:1,language:'en',document:blank};
const h=await openEditorHarness(configuration),{page,command,resources,events,errors,artifactRoot,blobRoot}=h;
try{
 const originalBlobs=(await readdir(blobRoot)).sort();
 resources.set(eventPaths[0],Buffer.from(eventFixture()));
 resources.set(eventPaths[1],Buffer.from(JSON.stringify({autosize:false,width:100,height:30,material:eventPaths[2],puppet:eventPaths[0]})));
 resources.set(eventPaths[2],Buffer.from(JSON.stringify({passes:[{defaultlight:false,shader:'genericimage4',textures:['editor/rig'],blending:'translucent',depthtest:'disabled',depthwrite:'disabled',cullmode:'nocull'}]})));
 resources.set(eventPaths[3],Buffer.from(solidPng([1,1,1,1])));
 await command({type:'thaw'});
 assert.deepEqual((await command({type:'snapshot'})).document,blank);
 const output=await page.evaluate(async({source,expected,files})=>{
  const api=await import('./script-api.mjs'),{SceneDocument}=await import('./document.mjs');
  const assert=(condition,message)=>{if(!condition)throw new Error(message);};
  const equal=(left,right,message)=>assert(JSON.stringify(left)===JSON.stringify(right),message);
  delete globalThis.__ScriptMustNotRun;
  for(const prefix of ['globalThis.__ScriptMustNotRun=true;','throw new Error("must not execute");','Function("globalThis.__ScriptMustNotRun=true")();','setTimeout(()=>globalThis.__ScriptMustNotRun=true,0);','fetch("http://127.0.0.1:1/script-probe");','import("http://127.0.0.1:1/script-probe.mjs");']){
   const body=prefix+' export function update(value){return value;}';
   assert(api.checkSceneScript(body).ok,'Real compiler rejected valid non-execution probe');
   const probe=new SceneDocument(source);api.prepareSceneScript(probe,{layerId:1,target:'color',type:'set',source:body});
   assert(!probe.canUndo&&!probe.dirty,'Prepare changed history');
  }
  await new Promise(resolve=>setTimeout(resolve,0));
  assert(!Object.hasOwn(globalThis,'__ScriptMustNotRun'),'Compiler executed source');
  const doc=new SceneDocument(source),edit={layerId:1,target:'color',type:'set',source:expected.scene.objects[0].color.script};
  let bad;
  try{api.prepareSceneScript(doc,{...edit,source:'export function update(value){\nreturn (;\n}'});}catch(error){bad=error;}
  assert(bad?.name==='SceneScriptSyntaxError'&&bad.layerId===1&&bad.target==='color'&&bad.line===bad.check.line&&bad.line>0,'Actual syntax error lost its structured diagnostic');
  assert(!doc.canUndo&&!doc.dirty,'Rejected syntax changed history');
  const diagnosticScene=structuredClone(source.scene);diagnosticScene.objects[0].color.scriptproperties={script:{custom:'not source'}};
  const report=api.checkSceneScriptSources(diagnosticScene);
  assert(report.ok&&report.checked===1&&report.unvalidated===1,'Unknown metadata was compiled or counted');
  assert(report.results.find(result=>!result.registered)?.checked===false,'Unknown source metadata was not explicit');
  const proposal=api.prepareSceneScript(doc,edit);assert(Object.isFrozen(proposal)&&Object.isFrozen(proposal.check),'Proposal is mutable');
  let rejected=false;try{api.applySceneScript(doc,{...proposal});}catch{rejected=true;}assert(rejected,'Forged proposal accepted');
  api.applySceneScript(doc,proposal);equal(doc.snapshot(),expected,'Source edit changed unrelated fields');
  rejected=false;try{api.applySceneScript(doc,proposal);}catch{rejected=true;}assert(rejected,'Proposal replay accepted');
  doc.undo();equal(doc.snapshot(),source,'Source undo not exact');assert(!doc.canUndo&&doc.canRedo,'Undo had extra revisions');
  doc.redo();equal(doc.snapshot(),expected,'Source redo not exact');assert(!doc.canRedo,'Redo left extra revisions');
  const stale=api.prepareSceneScript(doc,{...edit,source:source.scene.objects[0].color.script});doc.rename('Changed');
  rejected=false;try{api.applySceneScript(doc,stale);}catch{rejected=true;}assert(rejected,'Stale proposal accepted');doc.undo();
  const noOp=api.prepareSceneScript(doc,edit);api.applySceneScript(doc,noOp);doc.undo();equal(doc.snapshot(),source,'No-op added history');doc.redo();
  doc.markSaved();assert(!doc.dirty,'Saved standalone document remained dirty');
  const saved=JSON.stringify(doc.snapshot());equal(new SceneDocument(JSON.parse(saved)).snapshot(),expected,'Source JSON reparse changed document');
  const {buildScenePkg}=await import('./editor-api.mjs'),{buildEditorPackage}=await import('./package-archive.mjs');
  const inputs=files.map(file=>({path:file.path,data:Uint8Array.from(atob(file.data),c=>c.charCodeAt(0))}));
  inputs.push({path:'scene.json',data:new TextEncoder().encode(JSON.stringify(doc.snapshot().scene))});
  const pkg=buildEditorPackage(inputs,buildScenePkg);
  assert(pkg.pkg instanceof Uint8Array&&pkg.pkg.length>0,'Actual package builder produced no package');
  let encoded='';for(const byte of pkg.pkg)encoded+=String.fromCharCode(byte);
  assert(!Object.hasOwn(globalThis,'__ScriptMustNotRun'),'Source/package operations executed supplied probes');
  return {snapshot:doc.snapshot(),saved,pkg:btoa(encoded),diagnostic:{line:bad.line,target:bad.target},report};
 },{source,expected,files:[...resources].map(([name,data])=>({path:name,data:data.toString('base64')}))});
 assert.deepEqual(output.snapshot,expected);assert.deepEqual(JSON.parse(output.saved),expected);
 assert.deepEqual((await command({type:'snapshot'})).document,blank,'Standalone source operations changed live workbench');
 assert.equal(await page.locator('#layers button[data-layer-id]').count(),0);
 assert.equal(events.filter(event=>event.type==='resource'&&event.action==='stage').length,0);
 assert.deepEqual((await readdir(blobRoot)).sort(),originalBlobs,'Compiler-only operations wrote staged resources');
 for(const form of ['Loose','Package']){
  const directory=path.join(artifactRoot,'Script'+form);await mkdir(directory,{recursive:true});
  await writeFile(path.join(directory,'project.json'),JSON.stringify({...expected.project,file:form==='Loose'?'scene.json':'scene.pkg'}));
  if(form==='Package')await writeFile(path.join(directory,'scene.pkg'),Buffer.from(output.pkg,'base64'));
  else{
   await writeFile(path.join(directory,'scene.json'),JSON.stringify(expected.scene));
   for(const [name,data] of resources){const file=path.join(directory,name);await mkdir(path.dirname(file),{recursive:true});await writeFile(file,data);}
  }
 }
 await writeFile(path.join(artifactRoot,'script-contract-source.json'),JSON.stringify(source));
 await writeFile(path.join(artifactRoot,'script-contract-expected.json'),output.saved);
 assert.deepEqual(JSON.parse(await readFile(path.join(artifactRoot,'script-contract-expected.json'),'utf8')),expected);
 assert.deepEqual(errors,[]);
 console.log('Script contracts: actual browser compiler without source execution, structured diagnostics, standalone proposals/history/save, zero staging, unchanged blank workbench and real loose/PKG exports passed');
}finally{await h.close();}
