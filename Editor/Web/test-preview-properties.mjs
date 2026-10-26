import assert from 'node:assert/strict';
import { readFile,mkdir,writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { propertiesDocument,propertyDefaults,propertyChanges } from './preview-properties-fixture.mjs';

const require=createRequire(new URL('./.build/package.json',import.meta.url));
const {build}=require('esbuild'),{chromium}=require('playwright');
const repo=fileURLToPath(new URL('../../',import.meta.url));
const output=process.env.EDITOR_TEST_ARTIFACTS??path.join(repo,'.build/verification/editor-properties/browser-export');
// Bundle only the handwritten observer wrapper. Main runtime files remain the real
// source modules, so the red run can exercise missing command delivery before build.
const bundled=await build({entryPoints:[fileURLToPath(new URL('./scene-preview-script.mjs',import.meta.url))],nodePaths:[fileURLToPath(new URL('./.build/node_modules',import.meta.url))],bundle:true,platform:'browser',format:'esm',write:false,plugins:[{name:'same-engine',setup(b){b.onResolve({filter:/^webwallgl$/},()=>({path:'/__runtime/webwallgl.bundle.mjs',external:true}));}}]});
const browser=await chromium.launch({headless:true,...(process.env.SCENE_CHROMIUM_EXECUTABLE?{executablePath:process.env.SCENE_CHROMIUM_EXECUTABLE}:{})});
let serial=0;
try {
 async function start(){
  const page=await browser.newPage({viewport:{width:640,height:360}}),events=[],requests=[],errors=[];
  const origin=`http://property-preview-${++serial}.test`;
  await page.route(origin+'/**',async route=>{
   const request=route.request(),url=new URL(request.url());requests.push(url.pathname);
   if(url.pathname==='/__scene/event'){events.push(request.postDataJSON());return route.fulfill({json:{}});}
   if(url.pathname==='/__scene/spectrum')return route.fulfill({json:{sceneID:'property-browser',generation:1,left:Array(64).fill(0),right:Array(64).fill(0)}});
   if(url.pathname==='/__scene/config')return route.fulfill({json:{version:1,sceneID:'property-browser',generation:1,project:{representation:'loose',entryPath:'scene.json'},viewport:{width:640,height:360},fps:30,fit:'contain',volume:0,muted:true}});
   if(url.pathname==='/__project/project.json')return route.fulfill({json:propertiesDocument.project});
   if(url.pathname==='/__project/scene.json')return route.fulfill({json:propertiesDocument.scene});
   if(url.pathname.startsWith('/__project/'))return route.fulfill({status:404,body:''});
   if(url.pathname==='/__runtime/scene-preview-api.mjs')return route.fulfill({contentType:'text/javascript',body:Buffer.from(bundled.outputFiles[0].contents)});
   if(url.pathname==='/__runtime/scene-shell.mjs')return route.fulfill({contentType:'text/javascript',body:await readFile(path.join(repo,'Editor/Sources/EditorApp/Resources/ScenePreviewWeb/scene-shell.mjs'))});
   if(url.pathname.startsWith('/__runtime/')){const relative=url.pathname.slice(11);return route.fulfill({contentType:relative.endsWith('.mjs')?'text/javascript':relative.endsWith('.css')?'text/css':'text/html',body:await readFile(path.join(repo,'Sources/WallpaperApp/Resources/SceneRuntime',relative))});}
   return route.fulfill({status:404,body:''});
  });
  page.on('pageerror',error=>errors.push(String(error)));page.on('console',m=>{if(m.type()==='error')console.error('[properties browser]',m.text());});
  await page.goto(origin+'/__runtime/index.html');
  await page.waitForFunction(()=>globalThis.__propertyProbe?.frames>0);
  await page.waitForFunction(()=>globalThis.__dynamicWallpaperScene);
  assert(events.some(event=>event.type==='ready'),'Actual runtime did not report first frame');
  return {page,events,requests,errors,origin};
 }
 async function probe(h){return h.page.evaluate(()=>structuredClone(globalThis.__propertyProbe));}
 async function command(h,payload){const id='property-'+(++serial);await h.page.evaluate(value=>window.__dynamicWallpaperScene.command(value),{id,...payload});const failure=h.events.find(e=>e.type==='error');assert(!failure,`Actual live command failed: ${failure?.message}`);assert(h.events.some(e=>e.type==='command-ack'&&e.commandID===id),'Missing real command acknowledgement');}
 async function pixels(h,rgb){
  const image=await h.page.locator('#scene canvas').screenshot();
  const centers=await h.page.evaluate(async bytes=>{const bitmap=await createImageBitmap(new Blob([new Uint8Array(bytes)],{type:'image/png'}));const c=document.createElement('canvas');c.width=bitmap.width;c.height=bitmap.height;const ctx=c.getContext('2d');ctx.drawImage(bitmap,0,0);bitmap.close();return [120,320].map(x=>[...ctx.getImageData(x,180,1,1).data]);},[...image]);
  for(const [index,pixel] of centers.entries())for(let channel=0;channel<3;channel++)assert(rgb[channel]?pixel[channel]>240:pixel[channel]<15,`Actual ${index?'SceneScript callback':'bound color'} GPU pixel ${pixel} != ${rgb}`);
 }
 const h=await start();
 const initial=await probe(h);
 assert.deepEqual(Object.fromEntries(Object.entries(initial.values).filter(([key])=>Object.hasOwn(propertyDefaults,key))),{...propertyDefaults,tint:[0,1,0]},'Actual initial script values must be exact captured defaults');
 assert.equal(initial.top,1);assert.equal(initial.init,1);assert(initial.noOpener&&initial.noAuthoring);
 await pixels(h,[0,1,0]);
 const reads=h.requests.filter(name=>name.startsWith('/__project/'));
 await command(h,{type:'properties',properties:propertyChanges});
 await pixels(h,[1,0,0]);
 assert.deepEqual((await probe(h)).values,{...initial.values,...propertyChanges,tint:[1,0,0]});
 await command(h,{type:'properties',properties:propertyChanges});
 assert.equal((await probe(h)).top,1);assert.equal((await probe(h)).init,1);
 await command(h,{type:'pause'});await h.page.waitForTimeout(80);
 const frozen=await probe(h);
 await command(h,{type:'properties',properties:propertyDefaults});
 await pixels(h,[0,1,0]);
 const repainted=await probe(h);
 console.log('Actual pause/frame clocks',JSON.stringify({lastDisplayed:frozen.runtime,paused:repainted.runtime}));
 assert(repainted.frames>frozen.frames,'Paused patch did not execute an actual rendering frame');
 await h.page.waitForTimeout(100);assert.equal((await probe(h)).frames,repainted.frames,'Property repaint resumed paused playback');
 await command(h,{type:'properties',properties:propertyChanges});await pixels(h,[1,0,0]);
 assert.equal((await probe(h)).runtime,repainted.runtime,'Two paused forced frames changed the actual paused clock');
 await command(h,{type:'play'});await h.page.waitForTimeout(120);assert((await probe(h)).runtime>repainted.runtime,'Resume did not advance actual clock');
 assert.deepEqual(h.requests.filter(name=>name.startsWith('/__project/')),reads,'Property patch reread source files');
 assert.deepEqual(h.errors,[]);assert.equal((await probe(h)).init,1);
 const independent=await start();
 assert.deepEqual(Object.fromEntries(Object.entries((await probe(independent)).values).filter(([key])=>Object.hasOwn(propertyDefaults,key))),{...propertyDefaults,tint:[0,1,0]});
 await pixels(independent,[0,1,0]);await pixels(h,[1,0,0]);await independent.page.close();
 await h.page.close();
 const restarted=await start();assert.notEqual(restarted.origin,h.origin);
 assert.deepEqual(Object.fromEntries(Object.entries((await probe(restarted)).values).filter(([key])=>Object.hasOwn(propertyDefaults,key))),{...propertyDefaults,tint:[0,1,0]});await pixels(restarted,[0,1,0]);
 const builderPage=await browser.newPage();
 await builderPage.route('http://property-builder.test/**',async route=>{
  const pathname=new URL(route.request().url()).pathname;
  return route.fulfill(pathname.startsWith('/__builder/')?{contentType:'text/javascript',body:await readFile(path.join(repo,'Editor/Sources/EditorApp/Resources/EditorWeb',pathname.slice(11)))}:{contentType:'text/html',body:'<!doctype html><title>Owned fixture package encoder</title>'});
 });
 await builderPage.goto('http://property-builder.test/');
 const pkg=await builderPage.evaluate(async document=>{const {buildScenePkg}=await import('/__builder/editor-api.mjs'),{buildEditorPackage}=await import('/__builder/package-archive.mjs');const result=buildEditorPackage([{path:'scene.json',data:new TextEncoder().encode(JSON.stringify(document.scene))}],buildScenePkg);return Array.from(result.pkg);},propertiesDocument);
 await builderPage.close();
 for(const form of ['Loose','Package']){const directory=path.join(output,'Properties'+form);await mkdir(directory,{recursive:true});await writeFile(path.join(directory,'project.json'),JSON.stringify({...propertiesDocument.project,file:form==='Loose'?'scene.json':'scene.pkg'}));await writeFile(path.join(directory,form==='Loose'?'scene.json':'scene.pkg'),form==='Loose'?JSON.stringify(propertiesDocument.scene):Buffer.from(pkg));}
 assert.deepEqual(restarted.errors,[]);
 const beforeRejected=await probe(restarted),invalidID='atomic-invalid';
 await restarted.page.evaluate(value=>window.__dynamicWallpaperScene.command(value),{id:invalidID,type:'properties',properties:{enabled:false,notDeclared:1}});
 const rejectionDeadline=Date.now()+1000;
 while(!restarted.events.some(event=>event.type==='error')&&Date.now()<rejectionDeadline)await restarted.page.waitForTimeout(10);
 assert(restarted.events.some(event=>event.type==='error'&&event.message.includes('Unknown property: notDeclared')),'Actual command did not expose the unknown-property error');
 assert(!restarted.events.some(event=>event.type==='command-ack'&&event.commandID===invalidID),'Rejected full patch was acknowledged');
 assert.deepEqual((await probe(restarted)).values,beforeRejected.values,'Invalid full patch partially changed actual SceneScript values');
 assert.equal((await probe(restarted)).apply,beforeRejected.apply,'Invalid full patch invoked actual SceneScript callback');
 await restarted.page.close();
 console.log('Live properties: actual scalar defaults/callbacks, direct-bound GPU colors, repeated patch, paused real repaint/frozen clock, resume, no remount/source reread, fresh-origin defaults and actual loose/PKG fixture passed');
} finally {await browser.close();}
