import { createScene } from './webwallgl.bundle.mjs';
import { editorOf, buildScenePkg, checkWeCompat } from './editor-api.mjs';
import { controlled } from './document.mjs';
import { startEditor,validateEditorCommand } from './runtime.mjs';
import { messages } from './localization.mjs';
import { initializeInterface, renderWorkspace, setPlaybackState } from './interface.mjs';
import { Timeline } from './timeline.mjs';
import { ModelWorkspace } from './model-workspace.mjs';
import { GltfImport } from './gltf-import.mjs';

const $ = id => document.getElementById(id);
let displayedError;
let editor, selected, drag, editFailure, timeline, model, gltf, selectionPointer;
const pendingActions=new Set();
document.body.inert = true;
const showError = error => { displayedError=error;$('diagnostics').textContent = String(error?.message ?? error); };
try {
  const response = await fetch('/__editor/config', { redirect: 'error' });
  if (!response.ok) throw new Error(`Editor configuration: HTTP ${response.status}`);
  const config = await response.json(), t = messages(config.language);
  document.documentElement.lang = config.language ?? 'en';
  for (const element of document.querySelectorAll('[data-text]')) element.textContent = t[element.dataset.text];
  initializeInterface(t);
  const report = async payload => {
    const response = await fetch('/__editor/event', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), redirect: 'error' });
    if (!response.ok) throw new Error(`Editor event: HTTP ${response.status}`);
  };
  const runAction = operation => {
    const promise=Promise.resolve().then(operation);pendingActions.add(promise);
    void promise.catch(error=>{editFailure=error;showError(error);}).finally(()=>pendingActions.delete(promise));
    return promise;
  };
  const act = operation => runAction(async()=>{
    if(gltf?.error)throw gltf.error;await model?.flush();await timeline?.flush();editFailure=undefined;$('diagnostics').textContent='';
    await editor.change(operation);
  });
  const selectLayer = id => runAction(async()=>{if(gltf?.error)throw gltf.error;await model?.flush();await timeline?.flush();selected=id;update(editor.document);});
  function update(doc) {
    renderWorkspace({doc,selected,t,onSelect:id => { void selectLayer(id); },
      onPatch:(id,patch) => void act(doc => doc.patch(id,patch))});
    timeline?.update(doc,selected);
    model?.update(doc,selected);
  }
  editor = startEditor(config, { createScene, editorOf, buildScenePkg, checkWeCompat, element:$('canvas'), report, onChange:update, onError:showError,
    setEditingEnabled: value => { document.body.inert = !value;model?.setFrozen(!value);gltf?.setFrozen(!value); }, snapshotError: () => gltf?.error??editFailure,
    importModel:source=>gltf.open(source),
    onPlaybackChange: value => setPlaybackState(value,t) });
  timeline = new Timeline({editor,t,beforeEdit:()=>model?.flush(),edit:(id,property,edit)=>editor.change(doc=>doc.animate(id,property,edit)),onError:showError,
    onResetInput:()=>{editFailure=undefined;$('diagnostics').textContent='';}});
  model=new ModelWorkspace({editor,t,onError:showError,onResetInput:expected=>{if(!expected||editFailure===expected)editFailure=undefined;if(expected&&displayedError!==expected)return;displayedError=undefined;$('diagnostics').textContent='';}});
  gltf=new GltfImport({editor,t,onError:showError,onClose:(...expected)=>{if(expected.includes(editFailure))editFailure=undefined;if(expected.includes(displayedError)){displayedError=undefined;$('diagnostics').textContent='';}},onImported:async id=>{selected=id;update(editor.document);await model.activate(id);}});
  async function finishDrag() {
    if (!drag) return;
    const pending = drag; drag = undefined;
    if (pending.position) await act(doc => doc.patch(pending.id, {origin:pending.position.join(' ')}));
  }
  window.__dynamicWallpaperEditor = Object.freeze({ command: async value => {
    try { validateEditorCommand(value,config); } catch { return editor.command(value); }
    if (['snapshot','freeze','undo','redo','add-image','replace-resource','load','import-model'].includes(value.type)) {
      // Native menu/close commands do not necessarily blur the CEF text field.
      // Commit the visible value and pending drag before taking its snapshot.
      const focused = document.activeElement;
      const invalid = !focused?.closest?.('#model-brush-form') && focused?.checkValidity && !focused.checkValidity() ? focused.validationMessage : undefined;
      focused?.blur();
      if(value.type==='freeze'){document.body.inert=true;model.setFrozen(true);gltf.setFrozen(true);}
      try { await Promise.all([...pendingActions]);if(gltf.error)throw gltf.error;await finishDrag();await model.flush();await timeline.flush(); } catch(error) { editFailure=error;showError(error); }
      if (invalid) { editFailure = new Error(invalid); showError(editFailure); }
    }
    return editor.command(value);
  } });
  setPlaybackState(true,t);
  $('playback').addEventListener('click', () => {
    editor.setPlaying(!editor.playing); setPlaybackState(editor.playing,t);
  });
  $('project-title').addEventListener('change', event => { const title=event.target.value;void act(doc => doc.rename(title)); });
  for (const [id, operation] of Object.entries({ undo:doc => doc.undo(),redo:doc => doc.redo(),
    'add-text':doc => { selected = doc.addText(t.newText); },duplicate:doc => { selected = doc.duplicate(selected); },
    remove:doc => { doc.remove(selected); selected = undefined; },up:doc => doc.move(selected,1),down:doc => doc.move(selected,-1) })) $(id).addEventListener('click', () => void act(operation));
  $('inspector').addEventListener('submit', event => event.preventDefault());
  function moveCanvas(event) {
    if(selectionPointer&&selectionPointer.id===event.pointerId){selectionPointer.currentX=event.clientX;selectionPointer.currentY=event.clientY;}
    if(!drag)return;
    drag.position=[drag.origin[0]+(event.clientX-drag.x)/drag.scale,drag.origin[1]-(event.clientY-drag.y)/drag.scale,drag.origin[2]];
    void editor.controls.setLayerProps(drag.id,{origin:drag.position}).catch(showError);
  }
  $('canvas').addEventListener('pointerdown',event=>{
    const bounds=$('canvas').getBoundingClientRect(),hit=editor.controls?.hitTestAt(event.clientX-bounds.left,event.clientY-bounds.top);
    if(!hit?.length)return;
    const pointer={id:event.pointerId,down:true,x:event.clientX,y:event.clientY,currentX:event.clientX,currentY:event.clientY};selectionPointer=pointer;
    $('canvas').setPointerCapture(event.pointerId);
    void runAction(async()=>{
      await model.flush();await timeline.flush();selected=hit[0].id;update(editor.document);
      if(document.body.inert||(!pointer.down&&pointer.x===pointer.currentX&&pointer.y===pointer.currentY))return;
      const snapshot=editor.document.snapshot(),layer=snapshot.scene.objects.find(layer=>layer.id===selected),projection=snapshot.scene.general?.orthogonalprojection;
      if(layer&&!controlled(layer.origin)&&projection?.width>0&&projection?.height>0){
        const props=editor.controls.getLayerProps(selected);
        if(props){
          drag={id:selected,x:pointer.x,y:pointer.y,origin:props.origin,scale:Math.min(bounds.width/projection.width,bounds.height/projection.height)};
          if(pointer.currentX!==pointer.x||pointer.currentY!==pointer.y)moveCanvas({pointerId:pointer.id,clientX:pointer.currentX,clientY:pointer.currentY});
          if(!pointer.down)await finishDrag();
        }
      }
    });
  });
  $('canvas').addEventListener('pointermove',moveCanvas);
  for(const name of ['pointerup','pointercancel'])$('canvas').addEventListener(name,event=>{
    if(selectionPointer?.id===event.pointerId)selectionPointer.down=false;
    void finishDrag().catch(showError);
  });
  document.addEventListener('keydown', event => {
    if (document.body.inert||gltf.error) return;
    if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== 'z' || /INPUT|TEXTAREA|SELECT/.test(event.target.tagName)) return;
    event.preventDefault(); void act(doc => event.shiftKey ? doc.redo() : doc.undo());
  });
  await editor.ready;
  window.addEventListener('pagehide', () => { gltf.destroy();model.destroy();timeline.destroy();editor.destroy(); }, { once:true });
} catch (error) { showError(error); console.error('Editor preparation failed',error); }
