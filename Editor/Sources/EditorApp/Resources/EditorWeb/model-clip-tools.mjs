import { inspectClips,editModelClips } from './model-api.mjs';
import { captureClipSource,inspectClipReferences,commitClipResource,commitClipPlayback } from './model-clip-edit.mjs';
import { initializeClipsView } from './model-clips-view.mjs';
const $=id=>document.getElementById(id);
export class ModelClipTools {
 #options;#view;#draft=false;#selected;#bytes;#library;#unsupported;#failure;#dialog;#locked=false;
 constructor(options){
  this.#options=options;this.#view=initializeClipsView(options.t,options.parent);
  const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void options.run(async()=>{try{return await operation();}catch(error){this.#failure=error;throw error;}});});
  $('model-clip-form').addEventListener('input',()=>{this.#draft=true;this.#clear();});
  bind('model-clip-form','submit',()=>options.prepare());
  bind('model-clip-revert','click',()=>{this.#draft=false;this.#clear();this.render();});
  bind('model-clip-select','change',async()=>{const id=Number($('model-clip-select').value);try{await options.prepare();this.#selected=id;}finally{this.render();}});
  bind('model-clip-create','click',()=>this.#create(false));bind('model-clip-duplicate','click',()=>this.#create(true));
  bind('model-clip-delete','click',async()=>{await options.prepare();const {editor}=options,source=captureClipSource(editor,options.state().id,options.state().bytes),references=await inspectClipReferences(editor,source);this.#dialog={kind:'delete',source,clip:this.#clip()};this.#view.showDelete(this.#library.clips,this.#clip(),references);});
  bind('model-clip-preview','click',async()=>{await options.prepare();await options.editor.previewModelClip(options.state().id,this.#clip().id);});
  for(const [id,defaultPlayback] of [['model-clip-use',false],['model-clip-default',true]])bind(id,'click',async()=>{await options.prepare();this.#dialog={kind:'playback',source:captureClipSource(options.editor,options.state().id,options.state().bytes),clip:defaultPlayback?null:this.#clip()};this.#view.showPlayback(this.#dialog.clip);});
  bind('model-clip-create-dialog-form','submit',async()=>{
   this.#validate('model-clip-create-dialog-form');this.#assertDialog('create');const values=this.#view.newValues(),target=this.#dialog;
   const result=editModelClips(options.state().bytes,target.duplicate?{type:'duplicate',id:target.clip.id,name:values.name}:{type:'create',...values});
   this.#selected=result.id;await options.write(result.bytes,bytes=>commitClipResource(options.editor,target.source,bytes));this.#closeDialog('create');
  });
  bind('model-clip-delete-dialog-form','submit',async()=>{
   this.#validate('model-clip-delete-dialog-form');this.#assertDialog('delete');const target=this.#dialog,references=await inspectClipReferences(options.editor,target.source),replacement=this.#view.replacement();
   const result=editModelClips(options.state().bytes,{type:'delete',id:target.clip.id,referenced:references.referenced,...(replacement===undefined?{}:{replacement})});
   await options.write(result.bytes,bytes=>commitClipResource(options.editor,target.source,bytes,{deletedID:target.clip.id}));this.#closeDialog('delete');
  });
  bind('model-clip-playback-dialog-form','submit',async()=>{
   this.#assertDialog('playback');const target=this.#dialog;
   await commitClipPlayback(options.editor,target.source,target.clip?.id??null);this.#clear();this.#closeDialog('playback');
  });
  for(const kind of ['create','delete','playback']){
   const dialog=$(`model-clip-${kind}-dialog`);$(`model-clip-${kind}-dialog-cancel`).addEventListener('click',()=>{if(!this.#locked)this.#closeDialog(kind);});
   dialog.addEventListener('cancel',event=>{event.preventDefault();if(!this.#locked)this.#closeDialog(kind);});dialog.addEventListener('close',()=>{if(!dialog.open&&this.#dialog?.kind===kind)this.#releaseDialog();});
  }
 }
 #releaseDialog(){const barrier=this.#dialog?.barrier;this.#dialog=undefined;if(barrier)this.#options.reset(barrier);this.#clear();}
 #closeDialog(kind){if(this.#dialog?.kind===kind)this.#releaseDialog();$(`model-clip-${kind}-dialog`).close();}
 #clear(){if(this.#failure)this.#options.reset(this.#failure);this.#failure=undefined;}
 #clip(){const clip=this.#library?.clips.find(c=>c.id===this.#selected);if(!clip)throw new Error('Select a readable animation clip');return clip;}
 async #create(duplicate){await this.#options.prepare();const source=captureClipSource(this.#options.editor,this.#options.state().id,this.#options.state().bytes);this.#dialog={kind:'create',source,clip:duplicate?this.#clip():undefined,duplicate};this.#view.showCreate(this.#dialog.clip,duplicate);}
 #assertDialog(kind){const target=this.#dialog,state=this.#options.state();if(target?.kind!==kind||target.source.document!==this.#options.editor.document||target.source.id!==state.id||target.source.path!==state.source?.path||target.source.version!==state.source?.version)throw new Error('Model or animation source changed while the dialog was open');}
 #validate(id){const form=$(id),inputs=[...form.querySelectorAll('fieldset,input,select')],disabled=inputs.map(i=>i.disabled);try{inputs.forEach(i=>i.disabled=false);if(form.checkValidity())return;if(!document.body.inert)form.reportValidity();throw new Error(form.querySelector(':invalid')?.validationMessage??'Invalid clip input');}finally{inputs.forEach((input,i)=>input.disabled=disabled[i]);}}
 render(){
  const state=this.#options.state();if(!state.bytes)return;
  if(this.#bytes!==state.bytes){this.#bytes=state.bytes;try{this.#library=inspectClips(state.bytes);this.#unsupported=undefined;}catch(error){this.#library={clips:[]};this.#unsupported=error.message;}}
  if(!this.#library.clips.some(c=>c.id===this.#selected))this.#selected=this.#library.clips[0]?.id;
  const layer=this.#options.editor.document.snapshot().scene.objects?.find(l=>l.id===state.id);this.#view.render({clips:this.#library.clips,clip:this.#library.clips.find(c=>c.id===this.#selected),draft:this.#draft,unsupported:this.#unsupported,layer});this.#options.onSelection?.();
 }
 get draft(){return this.#draft;}set draft(value){this.#draft=value;}
 get selected(){return this.#selected;}
 get barrier(){if(!this.#dialog)return;return this.#dialog.barrier??=new Error('Finish or cancel the model dialog before saving or changing the scene');}
 applyDraft(bytes){try{this.#validate('model-clip-form');return editModelClips(bytes,{type:'update',id:this.#selected,...this.#view.values()}).bytes;}catch(error){this.#failure=error;throw error;}}
 async commit(bytes){try{const source=captureClipSource(this.#options.editor,this.#options.state().id,this.#options.state().bytes);return await commitClipResource(this.#options.editor,source,bytes);}catch(error){this.#failure=error;throw error;}}
 busy(value){this.#locked=value;this.#view.busy(value);}
}
