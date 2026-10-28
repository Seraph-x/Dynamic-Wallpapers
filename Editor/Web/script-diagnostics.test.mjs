import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const moduleURL = new URL('./script-diagnostics.mjs', import.meta.url);
const diagnostics = await import(moduleURL).catch(error => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const issue = overrides => ({layerId:1,layerName:'Layer',target:'alpha',phase:'update',message:'failure',line:3,count:1,...overrides});
const resourceSource = overrides => ({kind:'resource',path:'materials/雪.json',sha256:'a'.repeat(64),pointer:['passes',0,'constantshadervalues','颜色','script'],text:'// 😀\r\nexport function update(value){return value;}',...overrides});
const turn = () => new Promise(resolve => setImmediate(resolve));
function clock() {
  let next = 0;
  const pending = new Map();
  return {
    requestFrame(callback) { const id = ++next; pending.set(id, callback); return id; },
    cancelFrame(id) { pending.delete(id); },
    tick() { const work = [...pending.values()]; pending.clear(); work.forEach(callback => callback(0)); },
    get size() { return pending.size; },
  };
}

test('actual pinned editor source contains its read-only issue access entry', async () => {
  const source = await readFile(new URL('./.build/node_modules/@webwallgl/editor/webwallgl-editor.mjs', import.meta.url), 'utf8');
  assert.match(source, /getScriptIssues: \(\) => rt\.sceneCtl/);
  const packageInfo = JSON.parse(await readFile(new URL('./.build/node_modules/@webwallgl/editor/package.json', import.meta.url)));
  assert.equal(packageInfo.version, '3.0.0');
});

test('requires exactly seven typed fields without changing display strings', () => {
  assert.equal(typeof diagnostics.validateScriptIssue, 'function', 'missing actual issue schema validator');
  const value = issue({layerId:1.5,layerName:'',target:'\0世界',phase:'',message:'\0',line:null});
  assert.deepEqual(diagnostics.validateScriptIssue(value), value);
  assert.notEqual(diagnostics.validateScriptIssue(value), value);
  for (const bad of [null, [], {...issue(),extra:1}, Object.fromEntries(Object.entries(issue()).filter(([key]) => key !== 'line')), issue({layerId:NaN}), issue({layerId:Infinity}), issue({layerId:'1'}), issue({line:0}), issue({line:1.5}), issue({line:Number.MAX_SAFE_INTEGER+1}), issue({count:0}), issue({count:1.5}), issue({count:Infinity}), issue({message:1})]) {
    assert.throws(() => diagnostics.validateScriptIssue(bad), TypeError);
  }
  assert.equal(diagnostics.validateScriptIssue(issue({layerId:null,line:Number.MAX_SAFE_INTEGER,count:Number.MAX_SAFE_INTEGER})).layerId,null);
});

test('accepts only an exact validated resource source as the eighth field', () => {
  const value=issue({source:resourceSource()});
  const validated=diagnostics.validateScriptIssue(value);
  assert.deepEqual(validated,value);assert(Object.isFrozen(validated.source));assert(Object.isFrozen(validated.source.pointer));
  for(const source of [null,{},resourceSource({extra:1}),resourceSource({kind:'inline'}),resourceSource({path:'../x'}),resourceSource({path:'a//x'}),resourceSource({path:'x\0'}),resourceSource({sha256:'A'.repeat(64)}),resourceSource({pointer:['passes',true]}),resourceSource({pointer:['passes','\ud800']}),resourceSource({text:'\udfff'})])assert.throws(()=>diagnostics.validateScriptIssue(issue({source})),TypeError);
  assert.throws(()=>diagnostics.validateScriptIssue({...value,extra:1}),TypeError);
});

test('issue identity ignores real count and display location changes, preserves exact tuple', () => {
  assert.equal(typeof diagnostics.scriptIssueKey,'function');
  assert.equal(diagnostics.scriptIssueKey(issue()),diagnostics.scriptIssueKey(issue({count:9,layerName:'new',line:5})));
  assert.notEqual(diagnostics.scriptIssueKey(issue({target:'a|b',phase:'c'})),diagnostics.scriptIssueKey(issue({target:'a',phase:'b|c'})));
  assert.notEqual(diagnostics.scriptIssueKey(issue({layerId:null})),diagnostics.scriptIssueKey(issue({layerId:0})));
  assert.notEqual(diagnostics.scriptIssueKey(issue()),diagnostics.scriptIssueKey(issue({source:resourceSource()})));
  assert.notEqual(diagnostics.scriptIssueKey(issue({source:resourceSource()})),diagnostics.scriptIssueKey(issue({source:resourceSource({sha256:'b'.repeat(64)})})));
  assert.notEqual(diagnostics.scriptIssueKey(issue({source:resourceSource()})),diagnostics.scriptIssueKey(issue({source:resourceSource({pointer:['passes',1,'script']})})));
});

test('lossless UTF8 canonical base64 uses actual serialized 8192-byte framing budget', () => {
  assert.equal(typeof diagnostics.encodeScriptIssueParts,'function');
  const value = issue({layerName:'名称\0😀'.repeat(8000),target:'巨大'.repeat(9000),message:'',line:null});
  const identity = {sceneID:'scene-😀\\"'.repeat(8),generation:99,transferID:'f'.repeat(128)};
  const parts = diagnostics.encodeScriptIssueParts(value,identity);
  assert(parts.length>3);
  for (const [ordinal,part] of parts.entries()) {
    assert.deepEqual(Object.keys(part),['type','sceneID','generation','transferID','ordinal','final','data']);
    assert.equal(part.type,'script-issue-part');assert.equal(part.ordinal,ordinal);assert.equal(part.final,ordinal===parts.length-1);
    assert(Buffer.byteLength(JSON.stringify(part),'utf8')<=8192);
    assert.equal(Buffer.from(part.data,'base64').toString('base64'),part.data);
  }
  const decoded = Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64'))).toString('utf8');
  assert.deepEqual(JSON.parse(decoded),value);
  assert.throws(()=>diagnostics.encodeScriptIssueParts(value,{...identity,transferID:'a'.repeat(129)}),TypeError);
});

test('observer serializes every transfer, updates genuine counts, stops in-flight delivery', async () => {
  assert.equal(typeof diagnostics.observeScriptIssues,'function');
  const time=clock(),events=[],errors=[];let reads=0,records=[issue({layerName:'n'.repeat(22000)}),issue({target:'origin'})],release;
  const stop=diagnostics.observeScriptIssues({...time,sceneID:'scene',generation:1,read:()=>{reads++;return records;},createTransferID:(()=>{let id=0;return()=>`unique-${++id}`;})(),report:async (event,{signal})=>{events.push(event);assert(!signal.aborted);if(events.length===1)await new Promise(resolve=>{release=resolve;});},onError:error=>errors.push(error)});
  time.tick();await turn();assert.equal(reads,1);assert.equal(events.length,1);assert.equal(time.size,0);
  time.tick();await turn();assert.equal(reads,1);release();await turn();assert(events.length>2);assert.equal(time.size,1);
  const before=events.length;time.tick();await turn();assert.equal(events.length,before);
  records=[issue({layerName:'n'.repeat(22000),count:7}),issue({target:'origin'})];time.tick();await turn();
  assert.equal(JSON.parse(Buffer.concat(events.filter(event=>event.transferID==='unique-3').map(event=>Buffer.from(event.data,'base64'))).toString()).count,7);
  stop();assert.equal(time.size,0);time.tick();await turn();assert.deepEqual(errors,[]);
});

test('observer aborts in-flight reports and never schedules late work', async () => {
  const time=clock(),events=[],errors=[];let reportSignal,release;
  const stop=diagnostics.observeScriptIssues({...time,sceneID:'scene',generation:2,read:()=>[issue({layerName:'x'.repeat(24000)})],report:async(event,{signal})=>{events.push(event);reportSignal=signal;await new Promise(resolve=>{release=resolve;});},onError:error=>errors.push(error)});
  time.tick();await turn();stop();assert(reportSignal.aborted);release();await turn();assert.equal(events.length,1);assert.equal(time.size,0);assert.deepEqual(errors,[]);
});

test('read and report failures surface once and terminate polling', async () => {
  for (const kind of ['read','report']) {
    const time=clock(),errors=[],failure=new Error(kind);
    diagnostics.observeScriptIssues({...time,sceneID:'scene',generation:1,read:()=>{if(kind==='read')throw failure;return[issue()];},report:async()=>{throw failure;},onError:error=>errors.push(error)});
    time.tick();await turn();assert.deepEqual(errors,[failure]);assert.equal(time.size,0);
  }
});

test('default transfer identifiers use origin-independent cryptographic randomness', async () => {
  const time=clock(),events=[];
  const stop=diagnostics.observeScriptIssues({...time,sceneID:'scene',generation:1,read:()=>[issue(),issue({target:'color'})],report:async event=>events.push(event),onError:error=>{throw error;}});
  time.tick();await turn();stop();
  assert.equal(new Set(events.map(event=>event.transferID)).size,2);
  for(const event of events)assert.match(event.transferID,/^[0-9a-f]{32}$/);
});
