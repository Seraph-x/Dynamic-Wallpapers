import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,readFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import { SceneDocument } from './document.mjs';
import { discoverResourceScripts, discoverEditorResourceScripts } from './resource-scripts.mjs';
import { resourceDigest } from './resource-script-common.mjs';
import { captureResourceScript,prepareResourceScript,commitResourceScript } from './resource-script-edit.mjs';
const source='export function update(value){ return value; }';
const edited='globalThis.__externalSourceExecuted=true;\nexport function update(value){ return value * .5; }';
const resourcePath='materials/owned.json';
const encode=text=>new TextEncoder().encode(text),decode=bytes=>new TextDecoder('utf-8',{ignoreBOM:true}).decode(bytes);
const initial=()=>({title:'Source',entry:'scene.json',project:{type:'scene'},scene:{objects:[{id:1,effects:[{file:'effects/owned.json'}]}]}});
const raw=()=>'{\r\n "passes":[{"shader":"effects/owned","constantshadervalues":{"Strength":{"value":1e+0,"script":'+JSON.stringify(source)+',"big":9007199254740993,"future":1,"future":2}}}],\r\n "metadata":"untouched"\r\n}';
function gate(){let resolve;const promise=new Promise(finish=>{resolve=finish;});return {promise,resolve};}
async function fixture(){
 const originals=new Map([[resourcePath,encode(raw())],['effects/owned.json',encode('{"passes":[{"material":"materials/owned.json"}]}')]]),versions=new Map();
 const editor={document:new SceneDocument(initial()),closed:false,frozen:false,stages:0,
  async resourcePaths(){return [...originals.keys()];},
  async readResource(path){const version=this.document.snapshot().resourceOverrides?.[path];return version?new Uint8Array(versions.get(version)):new Uint8Array(originals.get(path));},
  async stageResource(bytes){this.stages++;const version=await resourceDigest(bytes);versions.set(version,new Uint8Array(bytes));return version;},
  async change(operation){operation(this.document);}};
 const report=await discoverEditorResourceScripts(editor);
 const record=report.records.find(record=>record.path===resourcePath&&record.editable);
 assert(record);return {editor,record,originals,versions};
}

test('compile-only checked proposals stage owned bytes and commit one exact undoable resource transaction',async()=>{
 const {editor,record,originals,versions}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited});
 assert.equal(Object.hasOwn(globalThis,'__externalSourceExecuted'),false);assert.equal(editor.stages,0);
 const result=await commitResourceScript(editor,proposal),saved=editor.document.snapshot();
 assert.equal(result.changed,true);assert.equal(editor.stages,1);assert.equal(Object.hasOwn(globalThis,'__externalSourceExecuted'),false);
 assert.equal(decode(versions.get(result.version)),raw().replace(JSON.stringify(source),JSON.stringify(edited)));
 assert.equal(decode(originals.get(resourcePath)),raw());assert.equal(saved.resourceOverrides[resourcePath],result.version);
 editor.document.undo();assert.deepEqual(editor.document.snapshot(),initial());assert.equal(editor.document.canUndo,false);
 editor.document.redo();assert.deepEqual(editor.document.snapshot(),saved);
 await assert.rejects(commitResourceScript(editor,proposal),/proposal|consumed|available/i);
});

test('syntax errors and no-op edits never stage; no-entry source has an actual checker warning',async()=>{
 const {editor,record}=await fixture(),capture=await captureResourceScript(editor,record);
 assert.throws(()=>prepareResourceScript(capture,{type:'set',source:'export function update(){\n return (; }'}),error=>error.name==='ResourceScriptSyntaxError'&&error.path===resourcePath&&Number.isInteger(error.line));
 assert.equal(editor.stages,0);assert.equal(editor.document.canUndo,false);
 const same=await commitResourceScript(editor,prepareResourceScript(capture,{type:'set',source}));assert.equal(same.changed,false);assert.equal(editor.stages,0);
 const noEntry=prepareResourceScript(capture,{type:'set',source:'globalThis.__externalSourceExecuted=true;'});assert(noEntry.diagnostics.some(value=>value.code==='NO_ENTRY'));assert.equal(Object.hasOwn(globalThis,'__externalSourceExecuted'),false);
});

test('forged records/captures/proposals and mutated public views cannot retarget a staged edit',async()=>{
 const {editor,record}=await fixture();await assert.rejects(captureResourceScript(editor,{...record}),/forged|record/i);
 const capture=await captureResourceScript(editor,record);assert.throws(()=>prepareResourceScript({...capture},{type:'remove'}),/capture|forged/i);
 const proposal=prepareResourceScript(capture,{type:'set',source:edited});assert.throws(()=>{proposal.anchor[0]='future';});
 await assert.rejects(commitResourceScript(editor,{...proposal}),/proposal|forged/i);assert.equal(editor.stages,0);
});

test('stage failure preserves draft/history; wrong returned hash never publishes',async()=>{
 for(const failure of [async()=>{throw new Error('Disk full');},async()=> 'a'.repeat(64)]){
  const {editor,record}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited});
  editor.stageResource=failure;await assert.rejects(commitResourceScript(editor,proposal),/Disk full|hash|corrupt/i);
  assert.deepEqual(editor.document.snapshot(),initial());assert.equal(editor.document.canUndo,false);
 }
});

test('pending stage cannot write through replacement, metadata, resource, freeze or close races',async()=>{
 for(const alter of [
  editor=>{editor.document=new SceneDocument(initial());},editor=>editor.document.rename('Changed'),
  editor=>editor.document.resource(resourcePath,'b'.repeat(64)),editor=>{editor.frozen=true;},editor=>{editor.closed=true;}
 ]){
  const {editor,record}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited}),entered=gate(),finish=gate();
  const stage=editor.stageResource.bind(editor);editor.stageResource=async bytes=>{const version=await stage(bytes);entered.resolve();await finish.promise;return version;};
  const pending=commitResourceScript(editor,proposal);await entered.promise;alter(editor);const expected=editor.document.snapshot();finish.resolve();
  await assert.rejects(pending,/changed|stale|frozen|closed/i);assert.deepEqual(editor.document.snapshot(),expected);
 }
});

test('out-of-band original byte changes are checked both before and after staging',async()=>{
 for(const after of [false,true]){
  const {editor,record,originals}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited});
  const alter=()=>originals.set(resourcePath,encode(raw()+' '));
  if(after){const stage=editor.stageResource.bind(editor);editor.stageResource=async bytes=>{const hash=await stage(bytes);alter();return hash;};}else alter();
  await assert.rejects(commitResourceScript(editor,proposal),/resource|changed|stale/i);assert.equal(editor.document.canUndo,false);assert.equal(editor.stages,after?1:0);
 }
});

test('last current-state check runs inside change and resource validation is pure and package-aware',async()=>{
 const {editor,record}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited});
 editor.change=async operation=>{editor.document.rename('Concurrent before callback');operation(editor.document);};
 await assert.rejects(commitResourceScript(editor,proposal),/changed|stale/i);assert.equal(editor.document.snapshot().resourceOverrides,undefined);
 const doc=new SceneDocument(initial(),'original.pkg');assert.throws(()=>doc.validateResource('original.pkg','a'.repeat(64)),/Reserved/);
 doc.validateResource(resourcePath,'a'.repeat(64));assert.deepEqual(doc.snapshot(),initial());assert.equal(doc.canUndo,false);
});

test('actual filesystem staging and saved-document reopen preserve original and edited resource bytes',async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'resource-script-'));
 try{
  const {editor,record,originals}=await fixture();await writeFile(path.join(directory,'original.json'),originals.get(resourcePath));
  editor.stageResource=async bytes=>{const version=await resourceDigest(bytes);await writeFile(path.join(directory,version),bytes,{flag:'wx'});return version;};
  const capture=await captureResourceScript(editor,record),result=await commitResourceScript(editor,prepareResourceScript(capture,{type:'set',source:edited}));
  await writeFile(path.join(directory,'workspace.json'),JSON.stringify(editor.document.snapshot()));
  const reopened=new SceneDocument(JSON.parse(await readFile(path.join(directory,'workspace.json'),'utf8'))),version=reopened.snapshot().resourceOverrides[resourcePath];
  assert.equal(version,result.version);assert.equal(await readFile(path.join(directory,version),'utf8'),raw().replace(JSON.stringify(source),JSON.stringify(edited)));
  assert.equal(await readFile(path.join(directory,'original.json'),'utf8'),raw());
 }finally{await rm(directory,{recursive:true});}
});

test('a nominal no-op still rejects source bytes changed after capture',async()=>{
 const {editor,record,originals}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source});
 originals.set(resourcePath,encode(raw()+' '));
 await assert.rejects(commitResourceScript(editor,proposal),/resource|changed|stale/i);assert.equal(editor.stages,0);assert.equal(editor.document.canUndo,false);
});

test('one opaque proposal cannot be committed concurrently and a failed stage remains retryable',async()=>{
 const {editor,record}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited}),entered=gate(),finish=gate();
 const stage=editor.stageResource.bind(editor);editor.stageResource=async bytes=>{entered.resolve();await finish.promise;return stage(bytes);};
 const first=commitResourceScript(editor,proposal);await entered.promise;
 const second=commitResourceScript(editor,proposal),outcomes=Promise.allSettled([first,second]);finish.resolve();
 const [success,failure]=await outcomes;assert.equal(success.status,'fulfilled');assert.equal(failure.status,'rejected');assert.match(failure.reason.message,/already.*committ/i);assert.equal(editor.stages,1);
 const retry=await fixture(),nextCapture=await captureResourceScript(retry.editor,retry.record),next=prepareResourceScript(nextCapture,{type:'set',source:edited}),realStage=retry.editor.stageResource.bind(retry.editor);
 retry.editor.stageResource=async()=>{throw new Error('Disk full');};await assert.rejects(commitResourceScript(retry.editor,next),/Disk full/);retry.editor.stageResource=realStage;
 assert.equal((await commitResourceScript(retry.editor,next)).changed,true);assert.equal(retry.editor.stages,1);
});

test('real PKG extraction and rebuilding retain original and unrelated resource bytes',async()=>{
 const {build}=createRequire(new URL('./.build/package.json',import.meta.url))('esbuild');
 const bundled=await build({stdin:{contents:'export {buildScenePkg} from "@webwallgl/editor";',resolveDir:fileURLToPath(new URL('./',import.meta.url))},nodePaths:[fileURLToPath(new URL('./.build/node_modules',import.meta.url))],bundle:true,format:'esm',platform:'node',write:false,metafile:true,treeShaking:true});
 assert(Object.values(bundled.metafile.outputs).every(output=>output.imports.length===0));
 const {buildScenePkg}=await import('data:text/javascript;base64,'+Buffer.from(bundled.outputFiles[0].contents).toString('base64'));
 const {buildEditorPackage,readEditorPackage}=await import('./package-archive.mjs');
 const {editor,originals,versions}=await fixture(),files=[...originals].map(([path,data])=>({path,data}));
 files.push({path:'scene.json',data:encode(JSON.stringify(initial().scene))},{path:'unknown.json',data:encode('{"huge":9007199254740993,"future":1,"future":2}')});
 const pkg=buildEditorPackage(files,buildScenePkg).pkg,originalHash=await resourceDigest(pkg),reader=readEditorPackage(pkg);
 const report=await discoverResourceScripts({snapshot:editor.document.snapshot(),paths:[...reader.paths],read:async path=>reader.read(path)}),record=report.records.find(value=>value.path===resourcePath&&value.editable);
 const capture=await captureResourceScript(editor,record),result=await commitResourceScript(editor,prepareResourceScript(capture,{type:'set',source:edited}));
 const exported=buildEditorPackage(reader.paths.map(path=>({path,data:path===resourcePath?versions.get(result.version):reader.read(path)})),buildScenePkg).pkg,roundtrip=readEditorPackage(exported);
 assert.equal(await resourceDigest(pkg),originalHash);
 assert.equal(decode(reader.read(resourcePath)),raw());assert.equal(decode(roundtrip.read(resourcePath)),raw().replace(JSON.stringify(source),JSON.stringify(edited)));
 assert.deepEqual(roundtrip.read('unknown.json'),reader.read('unknown.json'));assert.deepEqual(roundtrip.read('effects/owned.json'),reader.read('effects/owned.json'));
});

test('Editor-bound discovery records cannot be captured after an identical owner replacement',async()=>{
 const {editor,record}=await fixture();editor.document=new SceneDocument(initial());
 await assert.rejects(captureResourceScript(editor,record),/owner|stale|changed/i);assert.equal(editor.stages,0);
});

test('native dictionary reordering is equivalent while array changes keep captures stale',async()=>{
 const {editor,record}=await fixture(),snapshot=editor.document.snapshot.bind(editor.document),capture=await captureResourceScript(editor,record);
 editor.document.snapshot=()=>Object.fromEntries(Object.entries(snapshot()).reverse());
 const proposal=prepareResourceScript(capture,{type:'set',source:edited});assert.equal((await commitResourceScript(editor,proposal)).changed,true);
 const next=await fixture(),saved=next.editor.document.snapshot.bind(next.editor.document),held=await captureResourceScript(next.editor,next.record);
 next.editor.document.snapshot=()=>{const value=saved();value.scene.objects.push({id:2});return value;};
 assert.throws(()=>prepareResourceScript(held,{type:'remove'}),/changed|stale/i);assert.equal(next.editor.stages,0);
});

test('a render rejection after canonical mutation stays visible and consumes the proposal exactly once',async()=>{
 const {editor,record}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited});
 editor.change=async operation=>{operation(editor.document);throw new Error('Actual render failed');};
 await assert.rejects(commitResourceScript(editor,proposal),/Actual render failed/);
 assert.equal(typeof editor.document.snapshot().resourceOverrides[resourcePath],'string');
 await assert.rejects(commitResourceScript(editor,proposal),/consumed|available|proposal/i);
 editor.document.undo();assert.deepEqual(editor.document.snapshot(),initial());assert.equal(editor.document.canUndo,false);
});

test('an adapter that never invokes its mutation cannot fabricate a successful commit',async()=>{
 const {editor,record}=await fixture(),capture=await captureResourceScript(editor,record),proposal=prepareResourceScript(capture,{type:'set',source:edited}),change=editor.change.bind(editor);
 editor.change=async()=>{};await assert.rejects(commitResourceScript(editor,proposal),/did not apply/i);
 assert.deepEqual(editor.document.snapshot(),initial());editor.change=change;
 assert.equal((await commitResourceScript(editor,proposal)).changed,true);
});
