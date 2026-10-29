import test from 'node:test';
import assert from 'node:assert/strict';
import { startEditor,createWorkbenchScene } from './runtime.mjs';

const source='globalThis.__mustNotRun=true; export function update(value){return value;}';
const snapshot={title:'Editing',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{objects:[{id:1,alpha:{value:1,script:source}}]}};
test('authoring scene policy disables source evaluation without mutating caller options',()=>{
 const canvas={},options={scripts:true,fps:30,fit:'contain'},instance={};let received;
 assert.equal(createWorkbenchScene((element,value)=>{assert.equal(element,canvas);received=value;return instance;},canvas,options),instance);
 assert.equal(received.scripts,false);assert.equal(received.fps,30);assert.equal(options.scripts,true);assert.notEqual(received,options);
});
test('all workbench rebuilds keep source disabled and preserve the source document',async()=>{
 const mounts=[],scenes=[],reports=[];let time=0;
 const controls={get time(){return time;},setTimeScale(){},async seek(value){time=value;}};
 const canvas=()=>({style:{},getContext:()=>null}),element={replaceChildren(){},append(){},ownerDocument:{createElement:canvas}};
 const editor=startEditor({version:1,session:'edit',generation:1,document:snapshot},{element,
  createScene:(_,options)=>{mounts.push(options);return {async load(source){const directory=await source.sceneDir();scenes.push(JSON.parse(new TextDecoder().decode(await directory.read(directory.entry))));},setVolume(){},destroy(){}};},
  editorOf:()=>controls,report:async value=>reports.push(value),onChange(){},onError(error){throw error;},setEditingEnabled(){}});
 await editor.ready;await editor.command({type:'thaw',id:'thaw',session:'edit',generation:1});
 await editor.change(doc=>doc.rename('Changed'));await editor.command({type:'undo',id:'undo',session:'edit',generation:1});
 await editor.command({type:'redo',id:'redo',session:'edit',generation:1});
 await editor.command({type:'load',document:snapshot,id:'load',session:'edit',generation:1});
 assert.equal(mounts.length,5);assert(mounts.every(options=>options.scripts===false));
 assert(scenes.every(scene=>scene.objects[0].alpha.script===source));assert.deepEqual(editor.document.snapshot(),snapshot);
 editor.destroy();
});
test('Run preview reports only the transport request and never edits history',async()=>{
 const events=[];let frozen,fail;
 const controls={time:0,setTimeScale(){},async seek(){}};
 const canvas=()=>({style:{},getContext:()=>null}),element={replaceChildren(){},append(){},ownerDocument:{createElement:canvas}};
 const editor=startEditor({version:1,session:'edit',generation:1,document:snapshot},{element,
  createScene:()=>({async load(){},setVolume(){},destroy(){}}),editorOf:()=>controls,
  report:async value=>{if(value.type==='preview'&&fail)throw fail;events.push(value);},onChange(){},onError(){},setEditingEnabled:value=>frozen=!value});
 await editor.ready;await assert.rejects(editor.requestPreview(),/frozen/);
 await editor.command({type:'thaw',id:'thaw',session:'edit',generation:1});assert.equal(frozen,false);
 await editor.requestPreview();assert.deepEqual(events.filter(event=>event.type==='preview'),[{type:'preview',session:'edit',generation:1}]);
 assert.equal(editor.document.dirty,false);assert.equal(editor.document.canUndo,false);assert.deepEqual(editor.document.snapshot(),snapshot);
 fail=new Error('Preview request HTTP 503');await assert.rejects(editor.requestPreview(),/503/);fail=undefined;
 await editor.command({type:'freeze',id:'freeze',session:'edit',generation:1});await assert.rejects(editor.requestPreview(),/frozen/);
 editor.destroy();await assert.rejects(editor.requestPreview(),/closed/);
});
test('document changes retire readers before mutation and asynchronous rendering',async()=>{
 const events=[];
 const controls={time:0,setTimeScale(){},async seek(){}};
 const element={replaceChildren(){},append(){},ownerDocument:{createElement:()=>({style:{},getContext:()=>null})}};
 const editor=startEditor({version:1,session:'edit',generation:1,document:snapshot},{element,
  createScene:()=>({async load(){events.push('render');},setVolume(){},destroy(){}}),editorOf:()=>controls,
  onBeforeDocumentChange:()=>events.push('retire:'+editor.document.snapshot().title),
  report:async()=>{},onChange(){},onError(){},setEditingEnabled(){}});
 await editor.ready;events.length=0;
 await assert.rejects(editor.change(doc=>doc.rename('Frozen')),/frozen/);assert.deepEqual(events,[]);
 await editor.command({type:'thaw',id:'thaw',session:'edit',generation:1});
 await editor.change(doc=>{events.push('mutate');doc.rename('Changed');});
 assert.deepEqual(events,['retire:Editing','mutate','render']);events.length=0;
 await editor.command({type:'load',document:snapshot,id:'load',session:'edit',generation:1});
 assert.deepEqual(events,['retire:Changed','render']);editor.destroy();
});
