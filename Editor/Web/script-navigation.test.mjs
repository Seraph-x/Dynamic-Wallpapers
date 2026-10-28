import test from 'node:test';
import assert from 'node:assert/strict';
import { validateScriptLink,resolveScriptLink,scriptLineSelection } from './script-navigation.mjs';
const source='// 雪\r\nexport function update(value) {\r\n  return value;\r\n}\r\n';
const scene={objects:[{id:7,color:{value:'1 0 0',script:source}}]};
const link={documentIdentity:'capture',source,layerId:7,target:'color',path:['objects',0,'color','script'],line:3,registered:true};
const resource={kind:'resource',path:'materials/雪.json',sha256:'a'.repeat(64),pointer:['passes',0,'constantshadervalues','颜色','script'],text:source};
test('captured source links validate exact data fields without source execution',()=>{
 assert.deepEqual(validateScriptLink(link),link);
 for(const patch of [{extra:true},{line:0},{line:2.5},{registered:1},{source:12},{layerId:true},{path:['objects',-1]},{documentIdentity:''}])assert.throws(()=>validateScriptLink({...link,...patch}));
 assert.doesNotThrow(()=>validateScriptLink({...link,source:'\0 雪',layerId:null,registered:false}));
 const external={...link,path:resource.pointer,resource};assert.deepEqual(validateScriptLink(external),external);
 for(const changed of [{source:'different'},{path:['wrong']},{resource:{...resource,path:'../x'}},{resource:{...resource,sha256:'A'.repeat(64)}},{resource:{...resource,pointer:['passes',true]}}])assert.throws(()=>validateScriptLink({...external,...changed}));
});
test('only the same document and unique anchor with exact raw source can navigate current source',()=>{
 assert.equal(resolveScriptLink(link,{scene,documentIdentity:'capture'}).kind,'current');
 assert.equal(resolveScriptLink(link,{scene,documentIdentity:'other'}).reason,'document');
 assert.equal(resolveScriptLink(link,{scene:{objects:[{id:7,color:{value:'1 0 0',script:source.replaceAll('\r','')}}]},documentIdentity:'capture'}).reason,'source');
 for(const changed of [{objects:[]},{objects:[scene.objects[0],scene.objects[0]]}])assert.equal(resolveScriptLink(link,{scene:changed,documentIdentity:'capture'}).reason,'anchor');
 assert.equal(resolveScriptLink({...link,registered:false},{scene,documentIdentity:'capture'}).reason,'anchor');
 const reordered={objects:[{id:8},scene.objects[0]]};assert.equal(resolveScriptLink(link,{scene:reordered,documentIdentity:'capture'}).kind,'current');
 assert.equal(resolveScriptLink(link,{scene,documentIdentity:'capture',pending:true}).reason,'pending');
 assert.equal(resolveScriptLink({...link,path:resource.pointer,resource},{scene,documentIdentity:'capture'}).reason,'anchor');
});
test('reported lines reveal exact LF display positions, retaining unavailable/out-of-range values',()=>{
 assert.deepEqual(scriptLineSelection(source,3),{available:true,from:37,to:52,line:3});
 assert.equal(scriptLineSelection(source,null).reason,'missing');
 assert.equal(scriptLineSelection(source,99).reason,'outside');
 assert.equal(scriptLineSelection('a\nb\n',3).from,4);
 for(const start of ['import*as X','import *as X'])assert.equal(scriptLineSelection(start+"\n from 'WEMath';\nexport function update(value) {\n throw Error('x');\n}",3).reason,'transformed');
 assert.equal(scriptLineSelection("/* capture header */ import * as WEMath\n from 'WEMath';\nexport function update(value) {\n throw new Error('boom');\n}",3).reason,'transformed');
 assert.equal(scriptLineSelection("import * as X from 'WEMath';\nexport function update(value){return value;}",2).reason,'transformed');
});
