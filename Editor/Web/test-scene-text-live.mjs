import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {openScriptPlayback} from './script-migration-fixture.mjs';
import {bindingDocument} from './property-bindings-fixture.mjs';
import {SceneDocument} from './document.mjs';

const {PNG}=createRequire(import.meta.url)('./.build/node_modules/playwright-core/lib/utilsBundle.js');
const layout=page=>page.evaluate(()=>globalThis.__textWidgets.map(({layer,boxW,boxH,margin,canvas})=>({origin:layer.origin,localOrigin:layer.localOrigin,size:layer.size,boxW,boxH,margin,canvas:[canvas.width,canvas.height]})));
function assertFrame(actual,expected,message){
 const a=PNG.sync.read(actual),b=PNG.sync.read(expected);assert.deepEqual([a.width,a.height],[b.width,b.height],message);
 // Independent fresh/fresh controls on the pinned Metal browser differ by one
 // 8-bit level at glyph edges. Require every channel to stay within that measured
 // quantization error; geometry, script state and layout are asserted exactly.
 for(let i=0;i<a.data.length;i++)assert(Math.abs(a.data[i]-b.data[i])<=1,`${message}: channel ${i}, ${a.data[i]} != ${b.data[i]}`);
}

const original=structuredClone(bindingDocument),doc=new SceneDocument(original);
doc.bindProperty({type:'bind',layerId:3,field:'text',name:'caption'});
doc.bindProperty({type:'bind',layerId:3,field:'pointsize',name:'fontSize'});
const fixture=doc.snapshot();
fixture.project.general.properties.fontSize.min=0;
fixture.scene.general.zoom={value:1,script:`const host=({}).constructor.constructor('return globalThis')();const stats=host.__liveTextStats??={top:0,init:0,frames:0};stats.top++;
export function init(v){stats.init++;return v;}
export function update(v){stats.frames++;stats.time=engine.runtime;return v;}`};
const h=await openEditorHarness({version:1,session:'live-text',generation:1,language:'en',document:original});
const pages=[];
async function start(value){
 const page=await openScriptPlayback(h.page,value,new Map());pages.push(page);
 await page.waitForFunction(()=>globalThis.__bindingTextProbe&&globalThis.__liveTextStats?.frames>0);
 await page.evaluate(()=>{globalThis.__rasterCalls=[];globalThis.__originalFill=CanvasRenderingContext2D.prototype.fillText;CanvasRenderingContext2D.prototype.fillText=function(text,...args){globalThis.__rasterCalls.push({text:String(text),font:this.font});return globalThis.__originalFill.call(this,text,...args);};});
 return page;
}
const probe=page=>page.evaluate(()=>structuredClone(globalThis.__bindingTextProbe));
async function patch(page,values){await page.evaluate(async values=>{const result=globalThis.__migrationPlayback.setProperties(values);if(!result||typeof result.then!=='function')throw new Error('Public property update must return its actual rendering-frame promise');await result;},values);}
try{
 const page=await start(fixture);assert.deepEqual(await probe(page),{text:'Authored 雪',pointsize:40});
 const originalBytes=JSON.stringify(fixture);
 await patch(page,{caption:'Live 雪 😀',fontSize:48});
 assert.deepEqual(await probe(page),{text:'Live 雪 😀',pointsize:48});
 assert(await page.evaluate(()=>globalThis.__rasterCalls.some(call=>call.text.includes('Live 雪')&&/192px/.test(call.font))),'Actual Canvas2D text raster did not use live content/font');
 await page.evaluate(()=>globalThis.__migrationPlayback.pause());
 await patch(page,{caption:'Paused 雪',fontSize:20});
 const paused=await page.evaluate(()=>({...globalThis.__liveTextStats,paused:globalThis.__migrationPlayback.paused}));assert(paused.paused);
 assert.deepEqual(await probe(page),{text:'Paused 雪',pointsize:20});
 const pausedPixels=await page.locator('#scene canvas').screenshot();
 const pauseReference=structuredClone(fixture);pauseReference.project.general.properties.caption.value='Paused 雪';pauseReference.project.general.properties.fontSize.value=20;
 const pausedReference=await start(pauseReference);await pausedReference.evaluate(()=>globalThis.__migrationPlayback.pause());
 assert.deepEqual(await layout(page),await layout(pausedReference));
 assertFrame(pausedPixels,await pausedReference.locator('#scene canvas').screenshot(),'Paused acknowledgement preceded the new text GPU frame');
 await page.waitForTimeout(90);assert.deepEqual(await page.locator('#scene canvas').screenshot(),pausedPixels);
 assert.equal(await page.evaluate(()=>globalThis.__liveTextStats.frames),paused.frames,'Paused property update resumed the render loop');
 await patch(page,{caption:'Grow again 雪',fontSize:56});
 assert.equal(await page.evaluate(()=>globalThis.__liveTextStats.time),paused.time,'Repeated paused update advanced the actual clock');
 const largePixels=await page.locator('#scene canvas').screenshot();
 const fresh=structuredClone(fixture);fresh.project.general.properties.caption.value='Grow again 雪';fresh.project.general.properties.fontSize.value=56;
 const reference=await start(fresh);await reference.evaluate(()=>globalThis.__migrationPlayback.pause());
 const referencePixels=await reference.locator('#scene canvas').screenshot();
 assert.deepEqual(await layout(page),await layout(reference));
 assertFrame(largePixels,referencePixels,'Live grow layout differs from a fresh scene with identical authored defaults');
 await patch(page,{caption:'Small',fontSize:12});
 const small=structuredClone(fixture);small.project.general.properties.caption.value='Small';small.project.general.properties.fontSize.value=12;
 const smallReference=await start(small);await smallReference.evaluate(()=>globalThis.__migrationPlayback.pause());
 assert.deepEqual(await layout(page),await layout(smallReference));
 assertFrame(await page.locator('#scene canvas').screenshot(),await smallReference.locator('#scene canvas').screenshot(),'Live shrink layout differs from fresh defaults');
 const beforeRejected=await page.evaluate(()=>({properties:globalThis.__migrationPlayback.getProperties(),probe:globalThis.__bindingTextProbe}));
 await assert.rejects(patch(page,{caption:'must not apply',fontSize:0}),/positive|font size/i);
 assert.deepEqual(await page.evaluate(()=>({properties:globalThis.__migrationPlayback.getProperties(),probe:globalThis.__bindingTextProbe})),beforeRejected,'Invalid size partially applied the property patch');
 await patch(page,{caption:'',fontSize:24});assert.deepEqual(await probe(page),{text:'',pointsize:24});
 assert.deepEqual(await page.evaluate(()=>({top:globalThis.__liveTextStats.top,init:globalThis.__liveTextStats.init})),{top:1,init:1},'Live property updates remounted/reinitialized scripts');
 assert.equal(JSON.stringify(fixture),originalBytes,'Renderer changed the owned source fixture');
 assert.deepEqual(await page.evaluate(()=>globalThis.__playbackErrors),[]);
 // The upstream runtime-link WeakMap is used only in this fixture to delay
 // completion of a real GL draw. It does not replace/fake the renderer output.
 await page.evaluate(()=>{
  const runtime=globalThis[Symbol.for('webwallgl.runtime-link')].get(globalThis.__migrationPlayback),draw=runtime.renderer.render;
  let release;const gate=new Promise(resolve=>{release=resolve;});globalThis.__releaseHeldFrame=release;
  runtime.renderer.render=async function(...args){const result=await draw.apply(this,args);if(!globalThis.__heldFrameStarted){globalThis.__heldFrameStarted=true;await gate;}return result;};
  globalThis.__migrationPlayback.resume();
 });
 await page.waitForFunction(()=>globalThis.__heldFrameStarted);
 await page.evaluate(()=>{globalThis.__migrationPlayback.pause();globalThis.__lateFrameAck=false;globalThis.__lateUpdate=globalThis.__migrationPlayback.setProperties({caption:'Held frame 雪',fontSize:36}).then(()=>{globalThis.__lateFrameAck=true;});});
 await page.waitForTimeout(60);assert.equal(await page.evaluate(()=>globalThis.__lateFrameAck),false,'An older in-flight frame acknowledged the later patch');
 await page.evaluate(async()=>{globalThis.__releaseHeldFrame();await globalThis.__lateUpdate;});
 assert.deepEqual(await probe(page),{text:'Held frame 雪',pointsize:36});
 const heldReference=structuredClone(fixture);heldReference.project.general.properties.caption.value='Held frame 雪';heldReference.project.general.properties.fontSize.value=36;
 const heldFresh=await start(heldReference);await heldFresh.evaluate(()=>globalThis.__migrationPlayback.pause());
 assert.deepEqual(await layout(page),await layout(heldFresh));
 assertFrame(await page.locator('#scene canvas').screenshot(),await heldFresh.locator('#scene canvas').screenshot(),'Late patch acknowledgement did not include its actual new text pixels');
 await patch(page,{caption:'Fractional 雪',fontSize:0.5});
 const fractional=structuredClone(fixture);fractional.project.general.properties.caption.value='Fractional 雪';fractional.project.general.properties.fontSize.value=0.5;
 const fractionalFresh=await start(fractional);await fractionalFresh.evaluate(()=>globalThis.__migrationPlayback.pause());
 assert.deepEqual(await layout(page),await layout(fractionalFresh),'Fractional point size reflow differs from the pinned initial layout');
 assertFrame(await page.locator('#scene canvas').screenshot(),await fractionalFresh.locator('#scene canvas').screenshot(),'Fractional point size differs from fresh defaults');
 for(const anchor of ['left top','right bottom','none']){
  const boxed=structuredClone(fixture);Object.assign(boxed.scene.objects.find(object=>object.id===3),{size:'180 70',anchor,horizontalalign:'left',verticalalign:'top'});
  const live=await start(boxed);await live.evaluate(()=>globalThis.__migrationPlayback.pause());
  await patch(live,{caption:'Fixed box 雪',fontSize:18});
  boxed.project.general.properties.caption.value='Fixed box 雪';boxed.project.general.properties.fontSize.value=18;
  const fresh=await start(boxed);await fresh.evaluate(()=>globalThis.__migrationPlayback.pause());
  assert.deepEqual(await layout(live),await layout(fresh),`Bound text displaced ${anchor} anchored fixed box`);
  assertFrame(await live.locator('#scene canvas').screenshot(),await fresh.locator('#scene canvas').screenshot(),`Bound text clipped/displaced ${anchor} anchored fixed box`);
 }
 const scripted=structuredClone(fixture);scripted.scene.objects.find(object=>object.id===3).text.script='export function update(value){return "Script " + value;}';
 const scriptPage=await start(scripted);await scriptPage.evaluate(()=>globalThis.__migrationPlayback.pause());
 await patch(scriptPage,{caption:'bound 雪',fontSize:28});
 assert(await scriptPage.evaluate(()=>globalThis.__rasterCalls.some(call=>call.text.includes('Script bound 雪'))),'A direct property binding overrode the authored text update script');
 assert.deepEqual(await scriptPage.evaluate(()=>({top:globalThis.__liveTextStats.top,init:globalThis.__liveTextStats.init})),{top:1,init:1});
 const dispose=await start(fixture);
 const outcome=await dispose.evaluate(async()=>{globalThis.__migrationPlayback.pause();const result=globalThis.__migrationPlayback.setProperties({caption:'Closing',fontSize:32}).then(()=> 'resolved',error=>String(error.message));globalThis.__migrationPlayback.destroy();return result;});
 assert.match(outcome,/disposed|destroy/i,'Destroy fabricated success or orphaned the pending property frame');
 console.log('Live text: public frame promise, actual raster/paused GPU frame, frozen clock, grow/shrink/fixed-box anchors, script precedence, atomic rejection, no remount, in-flight ownership and destroy rejection passed');
}finally{for(const page of pages)await page.close();await h.close();}
