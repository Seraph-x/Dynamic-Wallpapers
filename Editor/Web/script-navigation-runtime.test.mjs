import test from 'node:test';
import assert from 'node:assert/strict';
import { startEditor,validateEditorCommand } from './runtime.mjs';
const value={title:'Identity',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{objects:[]}};
const link={documentIdentity:'captured',source:'invalid {',layerId:null,target:'general.zoom',path:['general','zoom','script'],line:null,registered:false};
test('document identity survives edits/save/undo but changes on load; navigation does not flush or mutate',async()=>{
 const events=[],reveals=[];let failure=new Error('Invalid pending source');
 const element={replaceChildren(){},append(){},ownerDocument:{createElement:()=>({style:{},getContext:()=>null})}};
 const config={version:1,session:'link',generation:1,document:value};
 const editor=startEditor(config,{element,createScene:()=>({async load(){},setVolume(){},destroy(){}}),editorOf:()=>({time:0,setTimeScale(){},async seek(){}}),report:async event=>events.push(event),onChange(){},onError(error){throw error;},setEditingEnabled(){},snapshotError:()=>failure,onRevealScript:async payload=>{reveals.push(payload);return {kind:'captured'};}});
 const command=async(type,extra={})=>{const id=String(events.length);await editor.command({id,session:'link',generation:1,type,...extra});return events.find(event=>event.id===id).payload;};
 await editor.ready;const captured=await command('freeze');assert.equal(typeof captured.documentIdentity,'string');assert(captured.documentIdentity);
 await command('thaw');const reply=await command('reveal-script',{link});assert.deepEqual(reply.navigation,{kind:'captured'});assert.equal(reveals.length,1);assert.equal(editor.document.dirty,false);assert.equal(editor.document.canUndo,false);
 failure=undefined;await editor.change(doc=>doc.rename('Changed'));assert.equal((await command('snapshot')).documentIdentity,captured.documentIdentity);
 await command('undo');assert.equal((await command('snapshot')).documentIdentity,captured.documentIdentity);
 await command('mark-saved',{document:editor.document.snapshot()});assert.equal((await command('snapshot')).documentIdentity,captured.documentIdentity);
 await command('load',{document:value});assert.notEqual((await command('snapshot')).documentIdentity,captured.documentIdentity);editor.destroy();
});
test('navigation payload is fixed data and rejects unknown or malformed fields',()=>{
 const config={session:'a',generation:1},command={session:'a',generation:1,id:'a',type:'reveal-script',link};
 assert.doesNotThrow(()=>validateEditorCommand(command,config));
 for(const patch of [{link:{...link,eval:'x'}},{link:{...link,line:-1}},{script:'x'}])assert.throws(()=>validateEditorCommand({...command,...patch},config));
});
