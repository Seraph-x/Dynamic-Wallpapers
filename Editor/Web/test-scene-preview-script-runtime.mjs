import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { migrationResources } from './script-migration-fixture.mjs';

const require = createRequire(new URL('./.build/package.json',import.meta.url));
const {build} = require('esbuild'), {chromium} = require('playwright');
const entry = new URL('./scene-preview-script.mjs',import.meta.url);
assert(await readFile(entry,'utf8').catch(()=>false),'missing Editor-only preview issue observer wrapper');
const bundled = await build({entryPoints:[entry.pathname],nodePaths:[new URL('./.build/node_modules',import.meta.url).pathname],bundle:true,platform:'browser',format:'esm',target:'chrome120',write:false,plugins:[{name:'shared-engine',setup(builder){builder.onResolve({filter:/^webwallgl$/},()=>({path:'/engine.mjs',external:true}));}}]});
const engine = await readFile(new URL('../../Sources/WallpaperApp/Resources/SceneRuntime/webwallgl.bundle.mjs',import.meta.url));
console.log('Launching actual preview renderer browser');
const browser = await chromium.launch({headless:true,...(process.env.SCENE_CHROMIUM_EXECUTABLE?{executablePath:process.env.SCENE_CHROMIUM_EXECUTABLE}:{})});
try {
  console.log('Actual preview browser launched');
  const page = await browser.newPage({viewport:{width:640,height:360}});
  page.on('console',message=>console.log('[renderer]',message.type(),message.text()));
  page.on('pageerror',error=>console.error('[renderer page error]',error));
  await page.route('http://issue-preview.test/**',route=>{
    const pathname=new URL(route.request().url()).pathname;
    return route.fulfill(pathname==='/engine.mjs'?{contentType:'text/javascript',body:engine}:pathname==='/observer.mjs'?{contentType:'text/javascript',body:Buffer.from(bundled.outputFiles[0].contents)}:{contentType:'text/html',body:'<!doctype html><div id="scene" style="width:640px;height:360px"></div>'});
  });
  console.log('Actual preview page created');
  await page.goto('http://issue-preview.test/');
  console.log('Actual preview fixture document loaded');
  const files=[...migrationResources()].map(([name,bytes])=>[name,Buffer.from(bytes).toString('base64')]);
  await page.evaluate(async files=>{
    console.log('Importing observer');
    const {createPreviewSceneFactory}=await Promise.race([import('/observer.mjs'),new Promise((_,reject)=>setTimeout(()=>reject(new Error('Actual observer import exceeded 15 seconds')),15000))]);
    console.log('Observer imported');
    const resources=new Map(files.map(([name,data])=>[name,Uint8Array.from(atob(data),c=>c.charCodeAt(0))]));
    resources.set('materials/editor/migration.json',new TextEncoder().encode(JSON.stringify({passes:[{shader:'editor/migration',textures:[],blending:'normal',constantshadervalues:{alpha:1}}]})));
    const sourceFor={
      parse:'export function update( {',
      init:'export function init(value) {\n  throw new Error("fixture-init");\n}',
      update:'export function update(value) {\n  throw new Error("fixture-update");\n}',
      timer:'export function init(value) {\n  engine.setTimeout(() => { throw new Error("fixture-timer"); }, 30);\n  return value;\n}',
      cursor:'export function cursorClick(event) {\n throw new Error("fixture-cursor");\n}',
      animation:'export function animationEvent(event, value) {\n throw new Error("fixture-animation");\n}',
    };
    const objects=Object.entries(sourceFor).map(([name,script],index)=>({id:index+1,name,image:'models/editor/rig.json',origin:'320 180 0',size:'100 30',scale:'1 1 1',angles:'0 0 0',color:{value:'0.8 0.6 0.4',script},alpha:1,animationlayers:[{animation:7,blend:1,rate:1,visible:true}]}));
    objects.push({id:7,name:'effect',image:'models/editor/material.json',origin:'500 80 0',size:'40 40',scale:'1 1 1',color:'1 1 1',alpha:1,effects:[{file:'effects/editor/migration.json',visible:{value:true,script:'export function update(value) { throw new Error("fixture-effect"); }'},passes:[]}]});
    const scene={general:{orthogonalprojection:{width:640,height:360},clearenabled:true,clearcolor:'0 0 0',cameraparallax:false,zoom:{value:1,script:'export function update(value) { throw new Error("fixture-general"); }'}},objects};
    const encode=value=>new TextEncoder().encode(JSON.stringify(value));
    const source={async project(){return {type:'scene',file:'scene.json'};},async sceneDir(){return {entry:'scene.json',async read(name){return name==='scene.json'?encode(scene):resources.get(name)??null;}};}};
    globalThis.__events=[];globalThis.__errors=[];globalThis.__diagnostics=[];
    const factory=createPreviewSceneFactory({sceneID:'actual-preview',generation:1,report:async(event,{signal})=>{if(signal.aborted)throw signal.reason;globalThis.__events.push(event);}});
    console.log('Creating actual scene');
    globalThis.__instance=factory(document.getElementById('scene'),{fps:30,volume:0,fit:'contain',audio:{snapshot:()=>({left:new Float32Array(64),right:new Float32Array(64)})},media:null,autoQuality:false,debugHooks:false,onError:error=>globalThis.__errors.push(String(error)),onDiagnostic:(message,level)=>globalThis.__diagnostics.push({message,level})});
    console.log('Loading actual scene');
    await Promise.race([globalThis.__instance.load(source),new Promise((_,reject)=>setTimeout(()=>reject(new Error('Actual scene load exceeded 15 seconds: '+JSON.stringify(globalThis.__errors))),15000))]);
  },files);
  await page.waitForTimeout(1200);
  await page.evaluate(async()=>{
    globalThis.__instance.pushPointer(285/640,0.5,0);
    await new Promise(resolve=>setTimeout(resolve,100));
    globalThis.__instance.pushPointer(285/640,0.5,1);
    await new Promise(resolve=>setTimeout(resolve,100));
    globalThis.__instance.pushPointer(285/640,0.5,0);
  });
  await page.waitForTimeout(150);
  const observed=await page.evaluate(()=>({events:globalThis.__events,errors:globalThis.__errors,diagnostics:globalThis.__diagnostics,keys:Object.keys(globalThis.__instance),paused:globalThis.__instance.paused}));
  assert.deepEqual(observed.errors,[]);
  const grouped=new Map();for(const event of observed.events){const parts=grouped.get(event.transferID)??[];parts.push(event);grouped.set(event.transferID,parts);}
  const issues=[...grouped.values()].map(parts=>JSON.parse(Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64'))).toString()));
  const names=new Set(issues.map(issue=>issue.layerName));
  for(const name of ['parse','init','update','cursor','animation','effect'])assert(names.has(name),`missing real ${name} issue: ${JSON.stringify(issues)}`);
  assert(!names.has('timer'),'pinned engine does not create structured timer issues');
  assert(observed.diagnostics.some(diagnostic=>diagnostic.level==='warn'&&diagnostic.message.includes('fixture-timer')),'real timer failure must remain visible as an unmapped generic engine warning');
  assert(issues.some(issue=>issue.layerId===null&&issue.target==='general.zoom'));
  const expected = {
    parse:{phase:'parse',line:null,count:1},init:{phase:'init',line:2,count:1},
    update:{phase:'update',line:2,count:3},cursor:{phase:'cursor',line:2,count:1},
    animation:{phase:'anim',line:2},effect:{phase:'update',line:1,count:3},
  };
  for(const [name,properties] of Object.entries(expected)) {
    const actual=issues.filter(issue=>issue.layerName===name).at(-1);
    for(const [field,value] of Object.entries(properties))assert.equal(actual[field],value,`${name} real ${field}`);
  }
  const general=issues.filter(issue=>issue.target==='general.zoom').at(-1);
  assert.deepEqual({layerId:general.layerId,layerName:general.layerName,line:general.line,count:general.count},{layerId:null,layerName:'',line:1,count:3});
  assert(!observed.keys.includes('editorOf')&&!observed.keys.includes('getScriptIssues'));
  await page.evaluate(()=>globalThis.__instance.pause());assert.equal(await page.evaluate(()=>globalThis.__instance.paused),true);
  await page.evaluate(()=>globalThis.__instance.resume());assert.equal(await page.evaluate(()=>globalThis.__instance.paused),false);
  const before=await page.evaluate(()=>{globalThis.__instance.destroy({releasePkgCache:true});return globalThis.__events.length;});
  await page.waitForTimeout(100);assert.equal(await page.evaluate(()=>globalThis.__events.length),before);
  console.log('Actual pinned renderer issues:',JSON.stringify(issues.map(({layerName,target,phase,line,count,message})=>({layerName,target,phase,line,count,message}))));
  console.log('Actual pinned observer transport, structured lifecycle failures plus genuine unmapped timer warning, real counts, live paused getter and destroy verified');
} finally {await browser.close();}
