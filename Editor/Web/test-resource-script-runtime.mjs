import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {resourceRuntimeFixture,runtimeResourceScript,runtimeResourceSinks} from './resource-script-fixtures.mjs';

const require=createRequire(new URL('./.build/package.json',import.meta.url));
const {build}=require('esbuild'),{chromium}=require('playwright');
const engine=await readFile(new URL('../../Sources/WallpaperApp/Resources/SceneRuntime/webwallgl.bundle.mjs',import.meta.url));
const api=await build({stdin:{contents:'export {createScene,editorOf} from "@webwallgl/editor";',resolveDir:new URL('./',import.meta.url).pathname},nodePaths:[new URL('./.build/node_modules',import.meta.url).pathname],bundle:true,platform:'browser',format:'esm',write:false,plugins:[{name:'shared-engine',setup(builder){builder.onResolve({filter:/^webwallgl$/},()=>({path:'/engine.mjs',external:true}));}}]});
async function mount(page,fixture){
 await page.route('http://owned-resource.test/**',route=>{
  const pathname=new URL(route.request().url()).pathname;
  return route.fulfill(pathname==='/engine.mjs'?{contentType:'text/javascript',body:engine}:pathname==='/api.mjs'?{contentType:'text/javascript',body:Buffer.from(api.outputFiles[0].contents)}:{contentType:'text/html',body:'<!doctype html><style>html,body{margin:0}#scene{width:320px;height:180px}</style><div id="scene"></div>'});
 });
 await page.goto('http://owned-resource.test/');
 await page.evaluate(async({files,options})=>{
  const {createScene,editorOf}=await import('/api.mjs'),resources=new Map(files.map(([path,data])=>[path,Uint8Array.from(atob(data),value=>value.charCodeAt(0))]));
  globalThis.__errors=[];globalThis.__diagnostics=[];
  const source={async project(){return {type:'scene',file:'scene.json'};},async sceneDir(){return {entry:'scene.json',async read(path){return resources.get(path)??null;}};}};
  globalThis.__source=source;
  globalThis.__makeInstance=async()=>{
   const instance=createScene(document.getElementById('scene'),{fps:30,fit:'contain',volume:0,media:null,autoQuality:false,debugHooks:false,bake:false,...options,onError:error=>globalThis.__errors.push(String(error)),onDiagnostic:(message,level)=>globalThis.__diagnostics.push({message,level})});
   globalThis.__instance=instance;await instance.load(source);globalThis.__controls=editorOf(instance);return instance;
  };
  await globalThis.__makeInstance();
 },{files:[...fixture.files].map(([path,data])=>[path,data.toString('base64')]),options:fixture.options});
}
async function observe(page,samples){
 return page.evaluate(samples=>{
  const canvas=document.querySelector('canvas'),gl=canvas.getContext('webgl2'),pixels=samples.map(([x,y])=>{const pixel=new Uint8Array(4);gl.readPixels(x,canvas.height-y,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);return [...pixel];});
  return {pixels,errors:globalThis.__errors,diagnostics:globalThis.__diagnostics,probe:globalThis.__resourceProbe??{},particles:globalThis.__particleStats?.(),issues:globalThis.__controls.getScriptIssues()};
 },samples);
}
const browser=await chromium.launch({headless:true,...(process.env.SCENE_CHROMIUM_EXECUTABLE?{executablePath:process.env.SCENE_CHROMIUM_EXECUTABLE}:{})});
const outcomes=[];
try{
 for(const sink of runtimeResourceSinks){
  const fixture=resourceRuntimeFixture(sink),page=await browser.newPage({viewport:{width:320,height:180}});
  try{
   await mount(page,fixture);
   await page.waitForTimeout(650);
   const observed=await observe(page,fixture.samples);
   assert.deepEqual(observed.errors,[]);
   const probe=observed.probe[sink];assert(probe?.top===1||sink==='mesh'&&probe?.top===2,`${sink}: actual resource initializer absent/duplicated: ${JSON.stringify(observed)}`);
   assert(probe.init>=1&&probe.update>=1,`${sink}: actual update absent`);
   if(['effect','mesh','per-mesh','tint','particle-uniform'].includes(sink)){
    assert(observed.pixels[0][1]>160&&observed.pixels[0][0]<60,`${sink}: actual green pixels missing: ${JSON.stringify(observed)}`);
    if(sink==='per-mesh')assert(observed.pixels[1][2]>160&&observed.pixels[1][0]<60,`${sink}: second mesh actual blue pixels missing: ${JSON.stringify(observed)}`);
   }else if(sink==='emitter-rate')assert(observed.particles.systems[0].live>15,`${sink}: no actual emitted particles: ${JSON.stringify(observed)}`);
   else assert(observed.pixels[0][0]>20&&observed.pixels[0][0]<100,`${sink}: expected actual dimmed pixels: ${JSON.stringify(observed)}`);
   outcomes.push({sink,status:'pass',observed});console.log('PASS',sink,JSON.stringify(observed));
  }catch(error){outcomes.push({sink,status:'fail',message:error.message});console.error('FAIL',sink,error.message);}
  finally{await page.close();}
 }
 {
  const sink='scripts-false',fixture=resourceRuntimeFixture('effect',{disabled:true}),page=await browser.newPage({viewport:{width:320,height:180}});
  try{await mount(page,fixture);await page.waitForTimeout(350);const observed=await observe(page,fixture.samples);
   assert.deepEqual(observed.errors,[]);assert.equal(observed.probe.effect,undefined);assert.deepEqual(observed.issues,[]);
   assert(observed.pixels[0][0]>160&&observed.pixels[0][1]<60,`${sink}: static red base was not preserved: ${JSON.stringify(observed)}`);
   outcomes.push({sink,status:'pass',observed});console.log('PASS',sink,JSON.stringify(observed));
  }catch(error){outcomes.push({sink,status:'fail',message:error.message});console.error('FAIL',sink,error.message);}finally{await page.close();}
 }
 {
  const sink='source-exception',source=runtimeResourceScript(sink,'throw new Error("OwnedResourceFailure");'),fixture=resourceRuntimeFixture('effect',{source}),page=await browser.newPage({viewport:{width:320,height:180}});
  try{await mount(page,fixture);await page.waitForTimeout(350);const observed=await observe(page,fixture.samples),issue=observed.issues[0];
   assert.deepEqual(observed.errors,[]);assert.equal(observed.issues.length,1);assert.equal(issue.message,'OwnedResourceFailure');assert.equal(issue.phase,'update');
   assert.deepEqual(issue.source.pointer,['passes',0,'constantshadervalues','Value','script']);assert.equal(issue.source.path,'materials/owned/effect.json');assert.equal(issue.source.text,source);assert.match(issue.source.sha256,/^[a-f0-9]{64}$/);
   assert(observed.pixels[0][1]<60,`${sink}: failed return was written as a successful green value: ${JSON.stringify(observed)}`);
   outcomes.push({sink,status:'pass',observed});console.log('PASS',sink,JSON.stringify(observed));
  }catch(error){outcomes.push({sink,status:'fail',message:error.message});console.error('FAIL',sink,error.message);}finally{await page.close();}
 }
 {
  const sink='reload-disposal',source=`const host=({}).constructor.constructor('return globalThis')();const probe=host.__resourceLifecycle??={top:0};const run=++probe.top;export function init(value){engine.setInterval(()=>probe['ticks'+run]=(probe['ticks'+run]??0)+1,5);return value;}export function update(){return {x:0,y:1,z:0,w:1};}`;
  const fixture=resourceRuntimeFixture('effect',{source}),page=await browser.newPage({viewport:{width:320,height:180}});
  try{await mount(page,fixture);await page.waitForTimeout(120);const before=await page.evaluate(()=>({...globalThis.__resourceLifecycle}));assert(before.ticks1>0);
   const stopped=await page.evaluate(()=>{globalThis.__instance.destroy({releasePkgCache:true});return {...globalThis.__resourceLifecycle};});await page.waitForTimeout(80);const afterStop=await page.evaluate(()=>({...globalThis.__resourceLifecycle}));assert.equal(afterStop.ticks1,stopped.ticks1);
   await page.evaluate(async()=>{document.getElementById('scene').replaceChildren();await globalThis.__makeInstance();});await page.waitForTimeout(120);const reloaded=await page.evaluate(()=>({...globalThis.__resourceLifecycle}));
   assert.equal(reloaded.top,2);assert.equal(reloaded.ticks1,afterStop.ticks1);assert(reloaded.ticks2>0);
   const closing=await page.evaluate(()=>{globalThis.__instance.destroy({releasePkgCache:true});return {...globalThis.__resourceLifecycle};});await page.waitForTimeout(80);const closed=await page.evaluate(()=>({...globalThis.__resourceLifecycle}));
   assert.equal(closed.ticks1,closing.ticks1);assert.equal(closed.ticks2,closing.ticks2);
   const observed={before,stopped,afterStop,reloaded,closing,closed};outcomes.push({sink,status:'pass',observed});console.log('PASS',sink,JSON.stringify(observed));
  }catch(error){outcomes.push({sink,status:'fail',message:error.message});console.error('FAIL',sink,error.message);}finally{await page.close();}
 }
}finally{await browser.close();}
const output=new URL('../../.build/verification/scene-resource-scripts/',import.meta.url);await mkdir(output,{recursive:true});await writeFile(new URL('renderer-outcomes.json',output),JSON.stringify(outcomes,null,2)+'\n');
assert.equal(outcomes.filter(value=>value.status==='fail').length,0,'Real renderer resource sinks failed');
