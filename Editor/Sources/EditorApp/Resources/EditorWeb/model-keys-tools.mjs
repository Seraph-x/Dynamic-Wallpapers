import { inspectBoneKeys,editBoneKeys } from './model-api.mjs';
import { captureClipSource,commitClipResource } from './model-clip-edit.mjs';
import { initializeKeysView } from './model-keys-view.mjs';
const $=id=>document.getElementById(id);
const equal=(a,b)=>a.length===b.length&&a.every((v,i)=>v===b[i]);
export class ModelKeysTools {
 #options;#view;#frame=0;#draft=false;#failure;#clipboard;#context;#cache;#info;#dialog;#locked=false;
 constructor(options){
  this.#options=options;this.#view=initializeKeysView(options.t,options.parent);
  const run=operation=>options.run(async()=>{try{await operation();}catch(error){this.#failure=error;this.#view.dialogError(error.message);throw error;}});
  const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void run(()=>operation(e));});
  $('model-key-form').addEventListener('input',()=>{this.#draft=true;this.#clear();});bind('model-key-form','submit',()=>options.prepare());bind('model-key-revert','click',()=>{this.#draft=false;this.#clear();options.onRevert();this.render();});
  bind('model-keys-frame','change',()=>this.#select($('model-keys-frame').valueAsNumber));
  $('model-key-ruler').addEventListener('click',event=>{if(this.#locked||!this.#info)return;const box=event.currentTarget.getBoundingClientRect(),frame=Math.round(Math.max(0,Math.min(1,(event.clientX-box.left)/box.width))*this.#info.frameCount);void run(()=>this.#select(frame));});
  for(const [id,direction] of [['previous',-1],['next',1]])bind('model-key-'+id,'click',async()=>{await options.prepare();const keys=this.#inspect(options.state().bytes).keys,available=keys.filter(f=>direction<0?f<this.#frame:f>this.#frame);if(!available.length)throw new Error('No adjacent bone key');this.#frame=direction<0?available.at(-1):available[0];this.render();});
  bind('model-key-copy','click',async()=>{await options.prepare();this.#clipboard=[...this.#inspect(options.state().bytes).pose];this.render();});
  bind('model-key-paste','click',async()=>{await options.prepare();if(!this.#clipboard)throw new Error('Copy a bone key first');this.#view.setPose(this.#clipboard);this.#draft=true;this.#clear();});
  bind('model-key-preview','click',async()=>{await options.prepare();const info=this.#inspect(options.state().bytes);await options.editor.previewModelClip(options.state().id,options.state().clip,info.frame/info.fps);});
  for(const type of ['add','remove','reduce'])bind('model-key-'+type,'click',async()=>{await options.prepare();await this.#edit({type});});
  for(const type of ['adopt','forget','move','duplicate'])bind('model-key-'+type,'click',async()=>{await options.prepare();const state=options.state(),info=this.#inspect(state.bytes);this.#dialog={type,source:this.#capture(),clip:state.clip,bone:state.bone,frame:this.#frame,bytes:state.bytes};this.#view.showDialog(type,info);});
  bind('model-key-dialog-form','submit',async()=>{const target=this.#target();this.#validate('model-key-dialog-form');const to=['move','duplicate'].includes(target.type)?this.#view.destination():undefined,bytes=editBoneKeys(target.bytes,{type:target.type,clip:target.clip,bone:target.bone,frame:target.frame,...(to===undefined?{}:{to})}),previous=this.#frame;try{if(to!==undefined)this.#frame=to;if(!equal(bytes,target.bytes))await options.write(bytes,value=>commitClipResource(options.editor,target.source,value));this.#close();}catch(error){this.#frame=previous;throw error;}finally{this.render();}});
  $('model-key-cancel').addEventListener('click',()=>{if(!this.#locked)this.#close();});$('model-key-dialog').addEventListener('cancel',event=>{event.preventDefault();if(!this.#locked)this.#close();});$('model-key-dialog').addEventListener('close',()=>{if(this.#dialog)this.#release();});
 }
 #selection(bone=this.#options.state().bone){return {clip:this.#options.state().clip,bone,frame:this.#frame};}
 #inspect(bytes,frame=this.#frame){return inspectBoneKeys(bytes,{...this.#selection(),frame});}
 #capture(){const state=this.#options.state();return captureClipSource(this.#options.editor,state.id,state.bytes);}
 #target(){const target=this.#dialog,state=this.#options.state();if(!target||target.source.document!==this.#options.editor.document||target.source.id!==state.id||target.source.path!==state.source?.path||target.source.version!==state.source?.version||target.clip!==state.clip||target.bone!==state.bone)throw new Error('Model or clip changed while the bone-key dialog was open');return target;}
 #validate(id){const form=$(id),inputs=[...form.querySelectorAll('fieldset,input')],disabled=inputs.map(input=>input.disabled);try{inputs.forEach(input=>input.disabled=false);if(form.checkValidity())return;if(!document.body.inert)form.reportValidity();throw new Error(form.querySelector('input:invalid')?.validationMessage||'Invalid bone key input');}finally{inputs.forEach((input,i)=>input.disabled=disabled[i]);}}
 #clear(){if(this.#failure)this.#options.reset(this.#failure);this.#failure=undefined;this.#view.dialogError('');}
 #release(){const barrier=this.#dialog?.barrier;this.#dialog=undefined;if(barrier)this.#options.reset(barrier);this.#clear();}
 #close(){this.#release();this.#view.close();this.render();}
 async #select(frame){try{await this.#options.prepare();this.#inspect(this.#options.state().bytes,frame);this.#frame=frame;}finally{this.render();}}
 async #edit(operation){const state=this.#options.state(),source=this.#capture(),bytes=editBoneKeys(state.bytes,{...this.#selection(),...operation});if(!equal(bytes,state.bytes))await this.#options.write(bytes,value=>commitClipResource(this.#options.editor,source,value));this.#clear();this.render();}
 render(){const state=this.#options.state(),context=[state.source?.document,state.id,state.source?.path,state.bone,state.clip];if(!this.#draft&&(!this.#context||context.some((v,i)=>v!==this.#context[i])))this.#frame=0;this.#context=context;let info,reason;
  if(state.bytes&&state.clip!==undefined)try{const cache=[state.bytes,state.bone,state.clip,this.#frame];if(this.#cache&&cache.every((v,i)=>v===this.#cache[i]))info=this.#info;else{const initial=this.#inspect(state.bytes,0);if(!this.#draft&&this.#frame>initial.frameCount)this.#frame=0;info=this.#frame===0?initial:this.#inspect(state.bytes);this.#cache=[state.bytes,state.bone,state.clip,this.#frame];this.#info=info;}}catch(error){reason=error.message;this.#info=undefined;}else {this.#cache=undefined;this.#info=undefined;}
  this.#view.render({state:info,draft:this.#draft,reason:this.#failure?.message??reason,bone:state.boneName??'',clipboard:Boolean(this.#clipboard)});
 }
 get draft(){return this.#draft;}set draft(value){this.#draft=value;}
 get barrier(){if(this.#dialog)return this.#dialog.barrier??=new Error('Finish or cancel the bone-key dialog before saving or changing the scene');}
 applyDraft(bytes,bone){try{this.#validate('model-key-form');return editBoneKeys(bytes,{type:'set',...this.#selection(bone),pose:this.#view.values()});}catch(error){this.#failure=error;throw error;}}
 async commit(bytes){try{await commitClipResource(this.#options.editor,this.#capture(),bytes);}catch(error){this.#failure=error;throw error;}}
 busy(value){this.#locked=value;this.#view.busy(value);}
 destroy(){this.#release();this.#view.destroy();}
}
