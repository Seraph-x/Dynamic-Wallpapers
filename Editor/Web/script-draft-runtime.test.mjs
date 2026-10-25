import test from 'node:test';
import assert from 'node:assert/strict';
import { startEditor } from './runtime.mjs';
test('native dirty notification and freeze include source-only drafts without altering history',async()=>{
 let draft=false;const events=[];
 const canvas=()=>({style:{},getContext:()=>null}),element={replaceChildren(){},append(){},ownerDocument:{createElement:canvas}};
 const value={title:'Draft',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{objects:[]}};
 const editor=startEditor({version:1,session:'draft',generation:1,document:value},{element,draftDirty:()=>draft,
  createScene:()=>({async load(){},setVolume(){},destroy(){}}),editorOf:()=>({time:0,setTimeScale(){},async seek(){}}),report:async value=>events.push(value),onChange(){},onError(error){throw error;},setEditingEnabled(){}});
 await editor.ready;
 assert.equal(typeof editor.notifyDirty,'function','Source drafts need a native dirty notification');
 draft=true;await editor.notifyDirty();assert.deepEqual(events.at(-1),{type:'dirty',dirty:true,session:'draft',generation:1});
 await editor.command({type:'freeze',id:'freeze',session:'draft',generation:1});
 assert.equal(events.find(event=>event.id==='freeze').payload.dirty,true);
 assert.deepEqual(editor.document.snapshot(),value);assert.equal(editor.document.dirty,false);assert.equal(editor.document.canUndo,false);
 draft=false;await editor.notifyDirty();assert.equal(events.at(-1).dirty,false);editor.destroy();
});
