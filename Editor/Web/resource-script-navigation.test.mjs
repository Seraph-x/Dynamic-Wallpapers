import test from 'node:test';
import assert from 'node:assert/strict';
import {SceneDocument} from './document.mjs';
import {resourceDigest} from './resource-script-common.mjs';
import * as navigation from './script-navigation.mjs';
const source='// 雪\r\nexport function update(value){return value;}';
async function fixture(){
 const path='materials/owned.json',bytes=new TextEncoder().encode(JSON.stringify({passes:[{shader:'effects/owned',constantshadervalues:{Value:{value:1,script:source}}}]}));
 const files=new Map([[path,bytes],['effects/owned.json',new TextEncoder().encode('{"passes":[{"material":"materials/owned.json"}]}')]]);
 const editor={document:new SceneDocument({title:'Navigation',entry:'scene.json',project:{type:'scene'},scene:{objects:[{id:1,effects:[{file:'effects/owned.json'}]}]}}),documentIdentity:'capture',closed:false,reads:0,async resourcePaths(){return [...files.keys()];},async readResource(path){this.reads++;return files.get(path);}};
 const resource={kind:'resource',path,sha256:await resourceDigest(bytes),pointer:['passes',0,'constantshadervalues','Value','script'],text:source};
 const link={documentIdentity:'capture',layerId:1,target:'constantshadervalues.Value',path:resource.pointer,source,line:2,registered:true,resource};
 assert.equal(typeof navigation.resolveEditorScriptLink,'function','Missing async resource navigation');return {editor,link,files};
}
test('resource reveal compares literal pointer, full digest and exact source before opening current editor',async()=>{
 const {editor,link}=await fixture();assert.equal((await navigation.resolveEditorScriptLink(link,{editor})).kind,'current');
 assert.equal((await navigation.resolveEditorScriptLink({...link,resource:{...link.resource,sha256:'a'.repeat(64)}},{editor})).reason,'source');
 const wrong=['passes',0,'constantshadervalues','Other','script'];assert.equal((await navigation.resolveEditorScriptLink({...link,path:wrong,resource:{...link.resource,pointer:wrong}},{editor})).reason,'anchor');
});
test('pending input and foreign documents use captured source without reading or committing',async()=>{
 const {editor,link}=await fixture();assert.equal((await navigation.resolveEditorScriptLink(link,{editor,pending:true})).reason,'pending');assert.equal(editor.reads,0);
 editor.documentIdentity='other';assert.equal((await navigation.resolveEditorScriptLink(link,{editor})).reason,'document');assert.equal(editor.reads,0);assert.equal(editor.document.canUndo,false);
});
test('revision changes during asynchronous navigation cannot reveal a stale current resource',async()=>{
 const {editor,link}=await fixture(),read=editor.readResource.bind(editor);editor.readResource=async path=>{const bytes=await read(path);editor.document.rename('Concurrent');return bytes;};
 assert.equal((await navigation.resolveEditorScriptLink(link,{editor})).reason,'document');
});
test('input becoming pending during a resource read keeps navigation in the captured view',async()=>{
 const {editor,link}=await fixture(),read=editor.readResource.bind(editor);let pending=false;
 editor.readResource=async path=>{const bytes=await read(path);pending=true;return bytes;};
 assert.equal((await navigation.resolveEditorScriptLink(link,{editor,hasPending:()=>pending})).reason,'pending');
});
