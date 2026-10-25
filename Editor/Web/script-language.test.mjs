import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { checkSceneScript } from '../Sources/EditorApp/Resources/EditorWeb/script-api.mjs';
import { migrationDocument } from './script-migration-fixture.mjs';
const language = await import('./script-language.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND' && error.url?.endsWith('/script-language.mjs')) return null;
  throw error;
});
const api = () => { assert(language, 'Missing positive SceneScript language catalogue'); return language; };
const targets = ['origin','scale','angles','color','alpha','brightness','maxwidth','pointsize','volume','intensity','exponent','visible','text','effects[0].visible'];
const ids = ['init','update','properties','cursor','media','animation','resize','timer','audio'];
const labels = (target, scope = '') => api().completionOptions(target,scope).map(option => option.label);

test('value classification uses the actual source target rather than its layer type', () => {
  for (const target of targets) assert.equal(api().scriptValueKind(target), ['origin','scale','angles','color'].includes(target) ? 'vector' : ['visible','effects[0].visible'].includes(target) ? 'boolean' : target === 'text' ? 'text' : 'scalar');
  for (const target of [undefined,null,{},'general.zoom','effects[01].visible','effects[-1].visible','effects[9007199254740992].visible','future.script']) assert.equal(api().scriptValueKind(target),'unknown');
});

test('positive top-level catalogue omits unavailable browser, host and text-only aliases', () => {
  for (const target of targets) {
    const options = api().completionOptions(target);
    for (const name of ['engine','input','Vec2','Vec3','Vec4','WEMath','WEColor','WEVector','thisLayer','thisScene','shared','scriptProperties','createScriptProperties','localStorage','Math','Date','export','function','return']) assert(labels(target).includes(name), target + ': ' + name);
    for (const name of ['window','document','fetch','console','globalThis','require','Function','mediaChanged','audioChanged','dispose','timer']) assert(!labels(target).includes(name), name);
    assert.equal(labels(target).includes('thisObject'),target !== 'text');
    assert.equal(new Set(options.map(o => o.label)).size,options.length);
    assert(options.every(o => typeof o.type === 'string' && typeof o.detail === 'string' && o.detail));
  }
  assert.deepEqual(api().completionOptions('unknown'),[]);
  assert.throws(() => api().completionOptions('color',null),/scope/i);
});

test('member catalogue distinguishes real numeric fields, vector values and sandbox shape', () => {
  for (const target of ['alpha','visible','text']) for (const name of ['x','y','z','add','multiply','copy']) assert(!labels(target,'value').includes(name));
  for (const name of ['x','y','z','add','multiply','copy']) assert(labels('origin','value').includes(name));
  assert(labels('text','value').includes('length')); assert(labels('text','value').includes('toUpperCase'));
  assert(labels('origin','thisLayer.origin').includes('add'));
  assert(labels('text','thisLayer.origin').includes('add'));
  assert(!labels('text','thisLayer.color').includes('add'));
  assert(labels('color','thisObject.color').includes('add'));
  assert.deepEqual(api().completionOptions('text','thisObject'),[]);
  for (const name of ['getLayerIndex','createLayer','destroyLayer','sortLayer','enumerateLayers']) assert(!labels('text','thisScene').includes(name));
  assert.deepEqual(labels('text','thisScene'),['getLayer']);
  for (const target of targets) {
    assert(!labels(target,'thisScene').includes('sortLayer'));
    for (const scope of ['engine.media','console','document','window','engine.unknownMember','unknown']) assert.deepEqual(api().completionOptions(target,scope),[]);
    for (const name of ['media','openUserShortcut','imaginaryAPI']) assert(!labels(target,'engine').includes(name));
    assert(labels(target,'engine').includes('registerAudioBuffers'));
    assert(labels(target,'input').includes('cursorWorldPosition'));
    assert(!labels(target,'engine.screenResolution').includes('divide'));
  }
  const factor = api().completionOptions('alpha','WEMath').find(o => o.label === 'deg2rad');
  assert.equal(factor.type,'constant');
  assert(labels('alpha','WEMath').includes('smoothStep'));
  assert(labels('alpha','WEColor').includes('hsv2rgb'));
  assert(labels('alpha','WEVector').includes('angleVector2'));
  assert(labels('alpha','Vec3').includes('fromSpherical'));
});

test('all stable template IDs have real compiler-valid complete starter modules', () => {
  for (const target of [...targets,'unknown']) {
    const templates = api().lifecycleTemplates(target);
    assert.deepEqual(templates.map(t => t.id),ids);
    for (const template of templates) {
      assert.equal(typeof template.available,'boolean');
      assert.equal(typeof template.source,'string'); assert(template.source.trim());
      const checked = checkSceneScript(template.source);
      assert.equal(checked.ok,true, target + '/' + template.id + ': ' + checked.message);
      assert.equal(checked.noEntry,false,target + '/' + template.id);
      assert(template.available ? template.reason === null : typeof template.reason === 'string' && template.reason.length > 0);
      assert.equal(checkSceneScript('globalThis.__languageMustNotRun=true;\n' + template.source).ok,true);
    }
  }
  assert.equal(Object.hasOwn(globalThis,'__languageMustNotRun'),false);
});

test('capability exclusions are explicit without changing existing source editability', () => {
  for (const target of targets) {
    const byID = Object.fromEntries(api().lifecycleTemplates(target).map(t => [t.id,t]));
    assert.equal(byID.media.available,false); assert.equal(byID.media.reason,'MEDIA_HOST_DISABLED');
    assert.equal(byID.cursor.available,!target.startsWith('effects['));
    if (target.startsWith('effects[')) assert.equal(byID.cursor.reason,'EFFECT_CURSOR_UNSUPPORTED');
    const unsafe = ['maxwidth','pointsize','volume','intensity','exponent'].includes(target);
    assert.equal(byID.animation.available,!unsafe);
    if (unsafe) assert.equal(byID.animation.reason,'ANIMATION_SCALAR_UNSUPPORTED');
    for (const id of ['init','update','properties','resize','timer']) assert.equal(byID[id].available,true,target + '/' + id);
    const missingInitial = ['maxwidth','pointsize','volume'].includes(target);
    assert.equal(byID.audio.available,!missingInitial);
    if (missingInitial) assert.equal(byID.audio.reason,'INITIAL_VALUE_UNAVAILABLE');
  }
  for (const template of api().lifecycleTemplates('unknown')) {
    assert.equal(template.available,false); assert.equal(template.reason,'UNSUPPORTED_TARGET');
  }
});

test('text starters retain a real update entry and catalogue generation preserves imported fixtures', async () => {
  const before = structuredClone(migrationDocument);
  for (const template of api().lifecycleTemplates('text')) if (template.available) assert(checkSceneScript(template.source).entries.includes('update'),template.id);
  for (const target of targets) { api().completionOptions(target); api().lifecycleTemplates(target); }
  assert.deepEqual(migrationDocument,before);
  assert.equal(Object.hasOwn(globalThis,'__migrationProbe'),false);
  assert.equal(Object.hasOwn(globalThis,'__migrationUnknownMetadataRan'),false);
  const code = await readFile(new URL('./script-language.mjs',import.meta.url),'utf8');
  assert(!/\beval\s*\(|new\s+Function\s*\(|\bimport\s*\(/.test(code));
});

test('catalogue callers cannot mutate future returned options or template records', () => {
  const first = api().completionOptions('origin','engine'); first[0].label = 'mutated'; first.push({label:'fake'});
  assert(!labels('origin','engine').includes('mutated')); assert(!labels('origin','engine').includes('fake'));
  const templates = api().lifecycleTemplates('origin'); templates[0].source = 'bad('; templates[0].available = false;
  assert.equal(api().lifecycleTemplates('origin')[0].available,true);
  assert.equal(checkSceneScript(api().lifecycleTemplates('origin')[0].source).ok,true);
});


test('missing scalar init values are exposed without first-update numeric compensation', () => {
  for (const target of ['maxwidth','pointsize','volume']) {
    const templates = Object.fromEntries(api().lifecycleTemplates(target).map(t => [t.id,t]));
    for (const id of ['init','update','properties','cursor','resize','timer']) {
      assert.match(templates[id].source,/export function update\(value\) \{\n  return value;/);
      assert(!templates[id].source.includes('new Vec3'));
      assert(!templates[id].source.includes('initial ='));
    }
    assert.match(templates.cursor.source,/shared\.cursorWorldPosition/);
    assert.match(templates.timer.source,/shared\.timerElapsed/);
  }
});

// Export the published factory functions through a temporary in-memory bundle.
// This executes the pinned implementation, without a browser or a replacement
// vector implementation; the production catalogue remains a static module.
async function pinnedVectorFactories() {
  const {createRequire} = await import('node:module');
  const require = createRequire(new URL('./.build/package.json',import.meta.url));
  const {build} = require('esbuild');
  const source = await readFile(new URL('./.build/node_modules/webwallgl/webwallgl.mjs',import.meta.url),'utf8');
  const start = source.indexOf('const VEC_EPS =');
  const end = source.indexOf('function textCanvasMargin(');
  assert(start > 0 && end > start,'Published sandbox module boundaries were not found');
  const result = await build({stdin:{contents:source.slice(start,end)+'\nexport {makeObjectLayerProxy,makeVec3,Vec3,makeInput,engineCanvasSize,WEMATH,WECOLOR,WEVECTOR};',resolveDir:new URL('./.build/node_modules/webwallgl/',import.meta.url).pathname},bundle:true,platform:'node',format:'esm',write:false,minify:true,logLevel:'silent'});
  return import('data:text/javascript;base64,'+Buffer.from(result.outputFiles[0].contents).toString('base64'));
}

test('member hints agree with the actual pinned layer-vector and angle factories', async () => {
  const {makeObjectLayerProxy,makeVec3} = await pinnedVectorFactories();
  const layer = {origin:[1,2,3],originalOrigin:[1,2,3],localOrigin:[1,2,3],scale:[1,1,1],localScale:[1,1,1],color:[0.2,0.4,0.6],size:[100,100,0],angles:[0,0,0],localAngles:[0,0,0]};
  const proxy = makeObjectLayerProxy(layer,{});
  for (const alias of ['thisLayer','thisObject']) for (const property of ['origin','originalOrigin','scale','color','size','angles']) {
    const value = proxy[property];
    for (const option of api().completionOptions('origin',alias+'.'+property)) {
      assert.equal(typeof value[option.label],option.type === 'function' ? 'function' : 'number',alias+'.'+property+'.'+option.label+' is not supplied by the pinned factory');
    }
  }
  // The text sandbox's origin is created by this same makeVec3 factory.
  for (const option of api().completionOptions('text','thisLayer.origin')) {
    assert.equal(typeof makeVec3([1,2,3])[option.label],option.type === 'function' ? 'function' : 'number','text thisLayer.origin.'+option.label);
  }
});

test('proxy-vector hints expose mutation while real Vec3 hints retain pure arithmetic', async () => {
  const {makeObjectLayerProxy,Vec3} = await pinnedVectorFactories();
  const layer = {origin:[1,2,3],localOrigin:[1,2,3],angles:[0,0,0],localAngles:[0,0,0]};
  const proxy = makeObjectLayerProxy(layer,{}),origin=proxy.origin;
  assert.equal(origin.add(new Vec3(1,0,0)),origin);
  assert.equal(origin.x,2);
  assert.equal(proxy.angles.add(new Vec3(0,0,10)).z,10);
  assert(Math.abs(layer.localAngles[2]-Math.PI/18)<1e-12,'Angle arithmetic must write through to the layer');
  for (const scope of ['thisLayer.origin','thisLayer.angles','thisObject.color']) {
    const add = api().completionOptions('origin',scope).find(option=>option.label === 'add');
    assert.match(add.detail+' '+(add.info??''),/mutat|in.place|writ/i,scope+' arithmetic must disclose mutation');
  }
  for (const scope of ['value','input.cursorPosition','engine.canvasSize']) {
    assert(labels('origin',scope).includes('normalize'),scope+' must retain actual Vec3 members');
    const vector = new Vec3(1,2,3);assert.notEqual(vector.add(new Vec3(1,0,0)),vector);assert.equal(vector.x,1);
  }
});


test('numeric, color and vector helper hints name actual pinned helper members', async () => {
  const {WEMATH,WECOLOR,WEVECTOR} = await pinnedVectorFactories();
  for (const [scope,actual] of Object.entries({WEMath:WEMATH,WEColor:WECOLOR,WEVector:WEVECTOR})) {
    for (const option of api().completionOptions('origin',scope)) {
      assert.equal(typeof actual[option.label],option.type === 'function' ? 'function' : 'number',scope+'.'+option.label+' is not supplied by the pinned runtime');
    }
  }
});
