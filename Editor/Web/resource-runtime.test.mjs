import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {createResourceOrigins} from '../../Resources/SceneScript/resource-source.mjs';
import * as runtime from '../../Resources/SceneScript/resource-runtime.mjs';

const require=createRequire(new URL('./.build/package.json',import.meta.url)),{build}=require('esbuild');
const upstream=await readFile(new URL('./.build/node_modules/webwallgl/webwallgl.mjs',import.meta.url),'utf8');
// Export the untouched pinned sandbox prefix without importing renderer/DOM side effects.
assert(upstream.includes('const textMod ='));
const bundled=await build({stdin:{contents:upstream.slice(0,upstream.indexOf('const textMod ='))+'\nexport {evalObjectScript};',resolveDir:new URL('./.build/node_modules/webwallgl/',import.meta.url).pathname},bundle:true,platform:'node',format:'esm',write:false,treeShaking:true});
const output=new URL('../../.build/verification/scene-resource-scripts/sandbox-api.mjs',import.meta.url);await mkdir(new URL('./',output),{recursive:true});await writeFile(output,bundled.outputFiles[0].contents);
globalThis.window={addEventListener(){}};
globalThis.document={addEventListener(){}};
const {evalObjectScript}=await import(output.href);
const encode=value=>new TextEncoder().encode(value);
function fixture(code,value='1 0 0 1'){
 const document={passes:[{shader:'effects/test',constantshadervalues:{Value:{value,script:code}}}]},origins=createResourceOrigins();
 origins.capture('materials/exact.json',encode(JSON.stringify(document)),document,'material');
 const issues=[],sandboxes=[],engine=runtime.createResourceScriptRuntime({origins,evaluate:evalObjectScript,environment:({layer})=>({layer,screenResolution:{x:320,y:180},userProperties:{},shared:{},setTimeout,clearTimeout,setInterval,clearInterval}),onIssue:record=>issues.push(record),onSandbox:record=>sandboxes.push(record)});
 return {engine,issues,sandboxes,wrapper:document.passes[0].constantshadervalues.Value};
}
const frame={runtime:1,frametime:1/30,timeOfDay:0.5,screenResolution:{x:320,y:180}};
const options=(layer,slot='pass0')=>({consumer:layer,layer,slot,key:'Value',kind:'effect',target:'constantshadervalues.Value'});
test('real pinned sandbox preserves scalar and exact vector2/3/4 values per consumer',()=>{
 for(const [base,returned,expected] of [[1,'0.5',0.5],['1 2','{x:3,y:4}','3 4'],['1 2 3','{x:3,y:4,z:5}','3 4 5'],['1 2 3 4','{x:3,y:4,z:5,w:6}','3 4 5 6']]){
  const {engine,wrapper,issues}=fixture('export function update(value){return '+returned+';}',base);
  assert.equal(engine.value(wrapper,options({id:1}),frame),expected);assert.deepEqual(issues,[]);engine.dispose();
 }
});
test('shared source has independent sandbox lifetime and thisLayer for each actual consumer slot',()=>{
 const {engine,wrapper,sandboxes}=fixture('let n=0;export function update(value){return ++n*thisLayer.alpha;}',1),left={id:1,alpha:0.25},right={id:2,alpha:0.5};
 assert.equal(engine.value(wrapper,options(left),frame),0.25);assert.equal(engine.value(wrapper,options(right),frame),0.5);
 assert.equal(engine.value(wrapper,options(left),frame),0.5);assert.equal(engine.value(wrapper,options(left,'pass1'),frame),0.25);
 assert.equal(sandboxes.length,3);engine.disposeLayers(new Set([left.id]));assert(sandboxes[0].sandbox.disabled);assert(!sandboxes[1].sandbox.disabled);
 engine.dispose();assert(sandboxes.every(value=>value.sandbox.disabled));
});
test('one shared renderer consumer still owns independent sandboxes per layer',()=>{
 const {engine,wrapper,sandboxes}=fixture('let n=0;export function update(){return ++n*thisLayer.alpha;}',1),consumer={},left={id:1,alpha:.25},right={id:2,alpha:.5};
 const shared=layer=>({...options(layer),consumer});
 assert.equal(engine.value(wrapper,shared(left),frame),.25);assert.equal(engine.value(wrapper,shared(right),frame),.5);
 assert.equal(engine.value(wrapper,shared(left),frame),.5);assert.equal(engine.value(wrapper,shared(right),frame),1);assert.equal(sandboxes.length,2);
 engine.disposeLayers(new Set([1]));assert(sandboxes[0].sandbox.disabled);assert(!sandboxes[1].sandbox.disabled);
 assert.equal(engine.value(wrapper,shared(right),frame),1.5);assert.equal(sandboxes.length,2);engine.dispose();
});
test('invalid typed returns and actual sandbox exceptions expose original descriptor without failed value writes',()=>{
 for(const body of ['return {x:1,y:2,z:3};','return NaN;','throw new Error("actual failure");']){
  const {engine,wrapper,issues}=fixture('export function update(value){'+body+'}');
  assert.equal(engine.value(wrapper,options({id:1}),frame),runtime.RESOURCE_SCRIPT_UNAVAILABLE);
  assert.equal(issues.length,1);assert.equal(issues[0].phase,'update');assert.equal(issues[0].source.path,'materials/exact.json');assert.equal(issues[0].source.text,wrapper.script);
  engine.dispose();
 }
});
test('disabled execution never constructs a sandbox or invokes its source initializer',()=>{
 const {wrapper}=fixture('throw new Error("must not execute"); export function update(value){return value;}',1),origins=createResourceOrigins(),document={passes:[{shader:'effects/test',constantshadervalues:{Value:wrapper}}]};
 origins.capture('materials/a.json',encode(JSON.stringify(document)),document,'material');
 const engine=runtime.createResourceScriptRuntime({origins,evaluate(){throw new Error('disabled evaluator invoked');},scripts:false,environment(){throw new Error('disabled environment invoked');},onIssue(){throw new Error('disabled issue invoked');}});
 assert.equal(engine.value(wrapper,options({id:1}),frame),wrapper);engine.dispose();
});
test('disposing a resource sandbox cancels its real timers without affecting another consumer',async()=>{
 globalThis.__resourceTimerTicks=0;
 const code='const host=({}).constructor.constructor("return globalThis")();export function init(value){engine.setInterval(()=>host.__resourceTimerTicks++,5);return value;}export function update(value){return value;}',{engine,wrapper}=fixture(code,1),layer={id:1};
 engine.value(wrapper,options(layer),frame);await new Promise(resolve=>setTimeout(resolve,25));assert(globalThis.__resourceTimerTicks>0);
 engine.disposeLayers(new Set([1]));const count=globalThis.__resourceTimerTicks;await new Promise(resolve=>setTimeout(resolve,25));assert.equal(globalThis.__resourceTimerTicks,count);engine.dispose();delete globalThis.__resourceTimerTicks;
});
