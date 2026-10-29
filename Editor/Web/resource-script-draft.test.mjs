import test from 'node:test';
import assert from 'node:assert/strict';
import {SceneDocument} from './document.mjs';
import {discoverEditorResourceScripts} from './resource-scripts.mjs';
import {resourceDigest} from './resource-script-common.mjs';

const draftModule=await import('./resource-script-draft.mjs').catch(error=>{
 if(error.code==='ERR_MODULE_NOT_FOUND'&&error.url?.endsWith('/resource-script-draft.mjs'))return {};
 throw error;
});
const source='export function update(value){return value;}',edited='export function update(value){return value*.5;}';
const path='materials/owned.json';
async function fixture(hasScript=true){
 const wrapper={value:1,...(hasScript?{script:source}:{})};
 const original=new TextEncoder().encode('{\r\n"passes":[{"shader":"effects/owned","constantshadervalues":{"Value":'+JSON.stringify(wrapper)+'}}],"huge":9007199254740993\r\n}');
 const files=new Map([[path,original],['effects/owned.json',new TextEncoder().encode('{"passes":[{"material":"materials/owned.json"}]}')]]),versions=new Map();
 const editor={document:new SceneDocument({title:'Draft',entry:'scene.json',project:{type:'scene'},scene:{objects:[{id:1,effects:[{file:'effects/owned.json'}]}]}}),closed:false,frozen:false,stages:0,
  async resourcePaths(){return [...files.keys()];},
  async readResource(name){const version=this.document.snapshot().resourceOverrides?.[name];return new Uint8Array(version?versions.get(version):files.get(name));},
  async stageResource(bytes){this.stages++;const hash=await resourceDigest(bytes);versions.set(hash,new Uint8Array(bytes));return hash;},
  async change(operation){operation(this.document);}};
 const record=(await discoverEditorResourceScripts(editor)).records.find(record=>record.path===path&&record.editable);
 assert.equal(typeof draftModule.ResourceScriptDraft?.open,'function','Missing async resource draft adapter');
 return {editor,original,draft:await draftModule.ResourceScriptDraft.open(editor,record)};
}
test('resource draft checks without execution and applies one lossless undoable edit',async()=>{
 const {editor,draft,original}=await fixture(),before=editor.document.snapshot();
 assert.equal(draft.state.kind,'script');assert.equal(draft.source,source);assert.equal(draft.dirty,false);
 draft.setSource(edited);assert.equal(draft.dirty,true);assert.equal(draft.check().ok,true);assert.equal(editor.stages,0);
 assert.equal(await draft.apply(),true);assert.equal(draft.dirty,false);assert.equal(draft.state.source,edited);
 const bytes=await editor.readResource(path);assert.equal(new TextDecoder().decode(bytes),new TextDecoder().decode(original).replace(JSON.stringify(source),JSON.stringify(edited)));
 assert.equal(await draft.apply(),false);assert.equal(editor.stages,1);
 editor.document.undo();assert.deepEqual(editor.document.snapshot(),before);assert.equal(editor.document.canUndo,false);
 editor.document.redo();assert.deepEqual(await editor.readResource(path),bytes);
});
test('syntax and staging failures preserve the actual input for correction or explicit revert',async()=>{
 const {editor,draft}=await fixture();draft.setSource('export function update(){return (;}');
 assert.throws(()=>draft.check(),error=>error.name==='ResourceScriptSyntaxError');assert.equal(draft.diagnostics[0].code,'SYNTAX');
 await assert.rejects(draft.apply(),/Unexpected|token|syntax/i);assert.equal(editor.stages,0);assert.equal(draft.dirty,true);
 draft.setSource(edited);const stage=editor.stageResource;editor.stageResource=async()=>{throw new Error('Disk full');};
 await assert.rejects(draft.apply(),/Disk full/);assert.equal(draft.source,edited);assert.equal(draft.dirty,true);assert.equal(editor.document.canUndo,false);
 editor.stageResource=stage;await draft.revert();assert.equal(draft.source,source);assert.equal(draft.dirty,false);
 draft.setSource(edited);await draft.apply();assert.equal(draft.source,edited);
});
test('empty script addition and removal retain source-only history semantics',async()=>{
 const {editor,draft}=await fixture(false);assert.equal(draft.state.kind,'constant');draft.setSource('');assert.equal(draft.dirty,true);
 assert.equal(await draft.apply(),true);assert.equal(draft.state.kind,'script');assert.equal(draft.source,'');
 draft.setSource('invalid source {');assert.equal(await draft.remove(),true);assert.equal(draft.state.kind,'constant');assert.equal(draft.dirty,false);
 assert.equal(await draft.remove(),false);assert.equal(editor.stages,2);
});
test('stale drafts reject apply and explicit revert adopts the current resource revision',async()=>{
 const {editor,draft}=await fixture();draft.setSource(edited);editor.document.rename('Another edit');
 assert.throws(()=>draft.check(),/changed|stale/);await assert.rejects(draft.apply(),/changed|stale/);assert.equal(draft.source,edited);
 await draft.revert();assert.equal(draft.source,source);assert.equal(draft.dirty,false);
});
