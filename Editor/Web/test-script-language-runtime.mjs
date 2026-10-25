import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { completionOptions,lifecycleTemplates,scriptValueKind } from './script-language.mjs';
import { migrationResources } from './script-migration-fixture.mjs';
const require = createRequire(new URL('./.build/package.json',import.meta.url));
const { chromium } = require('playwright');
const engine = await readFile(new URL('../Sources/EditorApp/Resources/ScenePreviewWeb/webwallgl.bundle.mjs',import.meta.url));
const runtimeResources = migrationResources();
// Reuse bytes and geometry, without executing the migration fixture's probe source.
runtimeResources.set('materials/editor/migration.json',Buffer.from(JSON.stringify({passes:[{shader:'editor/migration',textures:[],blending:'normal',constantshadervalues:{alpha:1}}]})));
const resources = [...runtimeResources].map(([name,bytes]) => [name,Buffer.from(bytes).toString('base64')]);
const targets = ['origin','scale','angles','color','alpha','brightness','maxwidth','pointsize','volume','intensity','exponent','visible','text','effects[0].visible'];
const bases = {origin:'320 180 0',scale:'1 1 1',angles:'0 0 0',color:'0.8 0.6 0.4',alpha:0.8,brightness:1,maxwidth:400,pointsize:20,volume:0.8,intensity:1,exponent:2,visible:true,text:'Hello'};
const browser = await chromium.launch({headless:true,...(process.env.SCENE_CHROMIUM_EXECUTABLE ? {executablePath:process.env.SCENE_CHROMIUM_EXECUTABLE} : {})});
let page;
const runtimeErrors = [];
async function mount(id,{level = 0,sourceFor} = {}) {
  if (page) runtimeErrors.push(...await page.evaluate(() => globalThis.__languageErrors));
  await page?.close(); page = await browser.newPage({viewport:{width:640,height:360}});
  const applicable = targets.filter(target => lifecycleTemplates(target).find(t => t.id === id).available);
  const objects = applicable.map((target,index) => {
    const layer = {id:index + 1,name:target,...bases,size:'100 30',font:'Arial',image:'models/editor/rig.json',animationlayers:[{animation:7,blend:1,rate:1,visible:true}]};
    if (target === 'text' || target === 'maxwidth' || target === 'pointsize') { delete layer.image; delete layer.animationlayers; }
    else delete layer.text;
    if (id === 'animation' && target === 'text') layer.origin = {value:'320 180 0',animation:{options:{fps:4,length:4,mode:'loop',events:[{frame:1,name:'middle'}]},c0:[{frame:0,value:320},{frame:4,value:320}],c1:[{frame:0,value:180}],c2:[{frame:0,value:0}]}};
    const source = sourceFor ? sourceFor(target) : lifecycleTemplates(target).find(t => t.id === id).source;
    if (target.startsWith('effects[')) layer.effects = [{file:'effects/editor/migration.json',visible:{value:true,script:source},passes:[]}];
    else layer[target] = {value:bases[target],script:source};
    return layer;
  });
  await page.route('http://language-runtime.test/**', route => new URL(route.request().url()).pathname === '/engine.mjs'
    ? route.fulfill({contentType:'text/javascript',body:engine})
    : route.fulfill({contentType:'text/html',body:'<!doctype html><style>body{margin:0}#scene{width:640px;height:360px}</style><div id="scene"></div>'}));
  await page.goto('http://language-runtime.test/');
  await page.evaluate(async ({objects,files,level}) => {
    const {createScene} = await import('/engine.mjs');
    const encode = value => new TextEncoder().encode(JSON.stringify(value));
    const resources = new Map(files.map(([name,data]) => [name,Uint8Array.from(atob(data),c => c.charCodeAt(0))]));
    const scene = {general:{orthogonalprojection:{width:640,height:360},clearenabled:true,clearcolor:'0 0 0',cameraparallax:false},objects};
    const source = {async project(){return {type:'scene',file:'scene.json',general:{properties:{enabled:{type:'bool',value:true}}}};},async sceneDir(){return {entry:'scene.json',async read(name){return name === 'scene.json' ? encode(scene) : resources.get(name) ?? null;}};}};
    globalThis.__languageErrors = [];
    globalThis.__languageScene = createScene(document.getElementById('scene'),{fps:30,volume:0,fit:'contain',audio:{snapshot:() => ({left:new Float32Array(64).fill(level),right:new Float32Array(64).fill(level)})},media:null,autoQuality:false,debugHooks:true,onError:error => globalThis.__languageErrors.push(String(error)),onDiagnostic:(message,type) => {if(type === 'warn' && /(?:script|脚本).*失败/.test(message))globalThis.__languageErrors.push(message);}});
    await globalThis.__languageScene.load(source);
  },{objects,files:resources,level});
  assert.equal(await page.evaluate(() => typeof globalThis.__migrationProbe),'undefined','Imported migration probe source must not run');
  return applicable;
}
async function values() {
  return page.evaluate(() => Object.fromEntries(globalThis.__scene.layers.map(layer => {
    const target = layer.name;
    const value = target === 'origin' ? layer.localOrigin : target === 'scale' ? layer.localScale : target === 'angles' ? layer.localAngles : target === 'maxwidth' ? layer.textMaxwidth : target === 'pointsize' ? layer.textPointsize : target === 'volume' ? layer.soundprops.volume : target === 'visible' ? layer.visibleSelf : target.startsWith('effects[') ? layer.effects[0].visible : layer[target];
    return [target,value];
  })));
}
function changed(target) {
  if (target === 'origin') return [330,180,0];
  if (target === 'scale') return [1.1,1.1,1.1];
  if (target === 'angles') return [0,0,10 * Math.PI / 180];
  if (target === 'color') return [0.4,0.3,0.2];
  if (scriptValueKind(target) === 'scalar') return bases[target] * 0.5;
  return target === 'text' ? 'Hello ✓' : false;
}
function near(actual,expected,label) {
  if (Array.isArray(expected)) { assert.equal(actual.length,expected.length,label); actual.forEach((value,index) => near(value,expected[index],label + '[' + index + ']')); }
  else if (typeof expected === 'number') assert(Math.abs(actual - expected) < 0.015,label + ': ' + actual + ' != ' + expected);
  else assert.equal(actual,expected,label);
}
const factoryScopes = ['engine','engine.screenResolution','engine.canvasSize','input','WEMath','WEColor','WEVector','Vec3','localStorage','MediaPlaybackEvent','Math','Date','thisLayer','thisObject','thisScene','value',...['cursorWorldPosition','cursorScreenPosition','cursorPosition','cursorPositionLast'].map(name => 'input.' + name),...['thisLayer','thisObject'].flatMap(name => ['origin','originalOrigin','scale','color','angles','size'].map(property => name + '.' + property))];
function factorySource(target) {
  // Trusted catalogue paths are emitted as direct expressions inside the real
  // sandbox. No author's source or completion result is evaluated by the UI.
  const checks = factoryScopes.filter(scope => completionOptions(target,scope).length).map(scope => {
    const members = completionOptions(target,scope).map(option => [option.label,option.type]);
    return `result[${JSON.stringify(scope)}] = ${JSON.stringify(members)}.map(([name,kind]) => ({name,kind,type:typeof (${scope})[name]}));`;
  }).join('\n');
  return `export function init(value) {
  const result = {};
  ${checks}
  const origin = thisLayer.origin;
  const before = [origin.x,origin.y,origin.z];
  const addSame = origin.add(new Vec3(2,3,4)) === origin;
  const added = [origin.x,origin.y,origin.z];
  const multiplySame = origin.multiply(2) === origin;
  const multiplied = [origin.x,origin.y,origin.z];
  const subtracted = origin.subtract(new Vec3(1,2,3));
  const divided = origin.divide(2);
  result.vectorSemantics = {before,addSame,added,multiplySame,multiplied,afterPure:[origin.x,origin.y,origin.z],subtracted:[subtracted.x,subtracted.y,subtracted.z],divided:[divided.x,divided.y,divided.z],layerOrigin:[thisLayer.origin.x,thisLayer.origin.y,thisLayer.origin.z]};
  ${target === 'text' ? '' : `const angles = thisLayer.angles;
  const old = [angles.x,angles.y,angles.z]; angles.x=0; angles.y=0; angles.z=0;
  const angleAddSame = angles.add(new Vec3(0,0,30)) === angles;
  const angleAdded = angles.z;
  const angleSubtractSame = angles.subtract(new Vec3(0,0,10)) === angles;
  const angleSubtracted = angles.z;
  const angleMultiplySame = angles.multiply(2) === angles;
  result.angleSemantics = {angleAddSame,angleAdded,angleSubtractSame,angleSubtracted,angleMultiplySame,angleMultiplied:angles.z,alias:thisObject === thisLayer};
  angles.x=old[0]; angles.y=old[1]; angles.z=${target === 'alpha' ? '30' : 'old[2]'};`}
  shared.catalogueFactories = shared.catalogueFactories || {};
  shared.catalogueFactories[${JSON.stringify(target)}] = result;
  return value;
}
export function update(value) { return value; }`;
}
async function verifyFactories() {
  await mount('init',{sourceFor:factorySource});
  const actual = await page.evaluate(() => globalThis.__shared.catalogueFactories);
  const missing = [];
  for (const target of targets) {
    assert(actual[target], 'Actual sandbox did not run factory inspection: ' + target);
    for (const scope of factoryScopes) for (const member of actual[target][scope] || []) {
      if (member.type === 'undefined' || member.kind === 'function' && member.type !== 'function') missing.push(target + '/' + scope + '.' + member.name + ': ' + member.type);
    }
  }
  assert.deepEqual(missing, [], 'Completion catalogue promised members absent from the actual pinned sandbox');
  for (const target of targets) {
    const result = actual[target].vectorSemantics, before = result.before;
    assert(result.addSame && result.multiplySame, target + ': snapshot add/multiply must mutate and return their receiver');
    near(result.added,before.map((value,index) => value + [2,3,4][index]),target + '/snapshot-add');
    near(result.multiplied,result.added.map(value => value * 2),target + '/snapshot-multiply');
    near(result.afterPure,result.multiplied,target + '/subtract-and-divide-preserve-receiver');
    near(result.subtracted,result.multiplied.map((value,index) => value - [1,2,3][index]),target + '/snapshot-subtract');
    near(result.divided,result.multiplied.map(value => value / 2),target + '/snapshot-divide');
    near(result.layerOrigin,target === 'text' ? result.multiplied : before,target + '/snapshot-versus-layer-origin');
    if (target !== 'text') {
      const angle = actual[target].angleSemantics;
      assert(angle.alias && angle.angleAddSame && angle.angleSubtractSame && angle.angleMultiplySame,target + '/live-angle-receiver-and-alias');
      near(angle.angleAdded,30,target + '/angle-add-degrees');near(angle.angleSubtracted,20,target + '/angle-subtract-degrees');near(angle.angleMultiplied,40,target + '/angle-multiply-degrees');
    }
  }
  near(await page.evaluate(() => globalThis.__scene.layers.find(layer => layer.name === 'alpha').localAngles[2]),Math.PI / 6,'Actual object angles write back radians to the rendered layer');
  console.log('SceneScript catalogue: every offered member checked inside actual object/effect/text factories; snapshot vector mutation, pure operations, aliases and live angle writeback passed');
}
try {
  await verifyFactories();
  await mount('init');
  let actual = await values();
  for (const target of targets) near(actual[target], target === 'origin' ? [320,180,0] : target === 'scale' ? [1,1,1] : target === 'angles' ? [0,0,0] : target === 'color' ? [0.8,0.6,0.4] : target.startsWith('effects[') ? true : bases[target], 'init/' + target);
  await mount('update');
  await page.waitForTimeout(180); actual = await values();
  for (const target of targets.filter(t => scriptValueKind(t) === 'scalar')) {
    if (['maxwidth','pointsize','volume'].includes(target)) near(actual[target],bases[target],'undefined init argument preserves ' + target);
    else assert.notEqual(actual[target],bases[target],'update/' + target + ' did not receive its real scalar baseline');
  }
  assert.match(actual.text,/^Hello \d+$/); assert(actual.origin[0] > 320); assert(actual.color[0] < 0.8);
  await mount('properties');
  assert.deepEqual(await page.evaluate(() => globalThis.__shared.userPropertyKeys),['enabled']);
  near((await values()).alpha,0.8,'properties preserves scalar');
  await mount('resize');
  assert.deepEqual(await page.evaluate(() => globalThis.__shared.screenSize),{x:640,y:360});
  await page.setViewportSize({width:720,height:400});
  await page.evaluate(() => { document.getElementById('scene').style.width = '720px'; document.getElementById('scene').style.height = '400px'; });
  await page.waitForFunction(() => globalThis.__shared.screenSize.x === 720 && globalThis.__shared.screenSize.y === 400);
  await mount('timer');
  await page.waitForTimeout(1150); actual = await values();
  assert.equal(await page.evaluate(() => globalThis.__shared.timerElapsed),true);
  near(actual.alpha,0.8,'timer preserves scalar'); assert.equal(actual.text,'Hello');
  near(actual.maxwidth,400,'timer preserves missing init scalar');
  const animated = await mount('animation');
  // The checked-in MDL has a real same-layer "middle" event at frame 1.
  await page.waitForTimeout(700); actual = await values();
  for (const target of animated) near(actual[target],changed(target),'animation/' + target);
  const clickable = await mount('cursor');
  for (const target of clickable) {
    const x = ['text','maxwidth','pointsize'].includes(target) ? 320 : 285;
    await page.evaluate(({target,x}) => {
      for (const layer of globalThis.__scene.layers) layer.visibleSelf = layer.visible = layer.name === target;
      globalThis.__languageScene.pushPointer(x / 640,0.5,0);
    },{target,x});
    await page.waitForTimeout(60);
    await page.evaluate(x => globalThis.__languageScene.pushPointer(x / 640,0.5,1),x); await page.waitForTimeout(80);
    await page.evaluate(x => globalThis.__languageScene.pushPointer(x / 640,0.5,0),x); await page.waitForTimeout(80);
    const event = await page.evaluate(() => globalThis.__shared.cursorWorldPosition);
    assert(event && Math.abs(event.x - x) < 1 && Math.abs(event.y - 180) < 1,'cursor/' + target + ': ' + JSON.stringify(event));
    await page.evaluate(() => { delete globalThis.__shared.cursorWorldPosition; });
  }
  await mount('audio'); await page.waitForTimeout(150); actual = await values();
  near(actual.alpha,0,'silent audio/alpha'); near(actual.color,[0.4,0.3,0.2],'silent audio/color'); assert.equal(actual.visible,false); assert.equal(actual.text,'Hello 0%');
  await mount('audio',{level:0.5}); await page.waitForTimeout(150); actual = await values();
  assert(actual.alpha > 0.1 && actual.alpha <= 0.8,'real injected audio scalar response');
  assert(actual.scale[0] > 1 && actual.scale[0] <= 1.1,'real injected audio vector response');
  assert.equal(actual.visible,true); assert.notEqual(actual.text,'Hello 0%');
  runtimeErrors.push(...await page.evaluate(() => globalThis.__languageErrors));
  assert.deepEqual(runtimeErrors,[]);
  console.log('SceneScript templates: actual pinned runtime init/update/properties/resize/timer/animation/cursor, scalar/vector/boolean/text and audio/silence passed');
} finally { await browser.close(); }
