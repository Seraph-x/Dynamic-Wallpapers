import { inspectFrameEvents,editFrameEvents } from './model-api.mjs';
import { captureClipSource,commitClipResource } from './model-clip-edit.mjs';
import { initializeEventsView } from './model-events-view.mjs';
const $=id=>document.getElementById(id);
export class ModelEventsTools {
 #options;#view;#selected=0;#draft=false;#failure;#dialog;#context;#bytes;#clip;#info;#reason;#locked=false;
 constructor(options){
  this.#options=options;this.#view=initializeEventsView(options.t,options.parent);
  const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void options.run(async()=>{try{await operation();}catch(error){this.#failure=error;throw error;}});});
  $('model-event-form').addEventListener('input',()=>{this.#draft=true;this.#clear();});bind('model-event-form','submit',()=>options.prepare());
  bind('model-event-revert','click',()=>{this.#draft=false;this.#clear();this.render();});
  bind('model-event-select','change',async()=>{const index=Number($('model-event-select').value);try{await options.prepare();if(!this.#info?.events[index])throw new Error('Animation event is unavailable');this.#selected=index;}finally{this.render();}});
  bind('model-event-add','click',async()=>{await options.prepare();const state=options.state();this.#dialog={kind:'create',source:this.#capture(),clip:state.clip};this.#view.showCreate(this.#info,this.#info.events[this.#selected]);});
  bind('model-event-duplicate','click',async()=>{await options.prepare();await this.#edit({type:'duplicate',index:this.#selected},this.#selected+1);});
  for(const [id,delta] of [['up',-1],['down',1]])bind('model-event-'+id,'click',async()=>{await options.prepare();await this.#edit({type:'move',index:this.#selected,to:this.#selected+delta},this.#selected+delta);});
  bind('model-event-delete','click',async()=>{await options.prepare();this.#dialog={kind:'delete',source:this.#capture(),clip:options.state().clip,index:this.#selected};this.#view.showDelete(this.#info.events[this.#selected]);});
  bind('model-event-create-form','submit',async()=>{this.#validate('model-event-create-form');const target=this.#target('create'),bytes=editFrameEvents(options.state().bytes,{type:'add',clip:target.clip,...this.#view.newValues()}),previous=this.#selected;try{this.#selected=this.#info.events.length;await options.write(bytes,value=>commitClipResource(options.editor,target.source,value));this.#close('create');}catch(error){this.#selected=previous;throw error;}finally{this.render();}});
  bind('model-event-delete-form','submit',async()=>{const target=this.#target('delete'),bytes=editFrameEvents(options.state().bytes,{type:'remove',clip:target.clip,index:target.index});await options.write(bytes,value=>commitClipResource(options.editor,target.source,value));this.#close('delete');});
  for(const kind of ['create','delete']){const dialog=$(`model-event-${kind}-dialog`);$(`model-event-${kind}-cancel`).addEventListener('click',()=>{if(!this.#locked)this.#close(kind);});dialog.addEventListener('cancel',e=>{e.preventDefault();if(!this.#locked)this.#close(kind);});dialog.addEventListener('close',()=>{if(!dialog.open&&this.#dialog?.kind===kind)this.#release();});}
 }
 #capture(){const state=this.#options.state();return captureClipSource(this.#options.editor,state.id,state.bytes);}
 #clear(){if(this.#failure)this.#options.reset(this.#failure);this.#failure=undefined;}
 #release(){const barrier=this.#dialog?.barrier;this.#dialog=undefined;if(barrier)this.#options.reset(barrier);this.#clear();}
 #close(kind){if(this.#dialog?.kind===kind)this.#release();this.#view.close(kind);this.render();}
 #target(kind){const target=this.#dialog,state=this.#options.state();if(target?.kind!==kind||target.source.document!==this.#options.editor.document||target.source.id!==state.id||target.source.path!==state.source?.path||target.source.version!==state.source?.version||target.clip!==state.clip)throw new Error('Model or clip changed while the event dialog was open');return target;}
 #validate(id){const form=$(id),controls=[...form.querySelectorAll('fieldset,input,textarea')],disabled=controls.map(e=>e.disabled);try{controls.forEach(e=>e.disabled=false);if(form.checkValidity())return;if(!document.body.inert)form.reportValidity();throw new Error(form.querySelector('input:invalid,textarea:invalid')?.validationMessage||'Invalid animation event input');}finally{controls.forEach((e,i)=>e.disabled=disabled[i]);}}
 async #edit(operation,next){const source=this.#capture(),state=this.#options.state(),bytes=editFrameEvents(state.bytes,{...operation,clip:state.clip}),previous=this.#selected;try{this.#selected=next;await this.#options.write(bytes,value=>commitClipResource(this.#options.editor,source,value));this.#clear();}catch(error){this.#selected=previous;throw error;}finally{this.render();}}
 render(){const state=this.#options.state(),context=[state.source?.document,state.id,state.source?.path,state.clip];if(!this.#draft&&(!this.#context||context.some((v,i)=>v!==this.#context[i])))this.#selected=0;this.#context=context;
  if(this.#bytes!==state.bytes||this.#clip!==state.clip){this.#bytes=state.bytes;this.#clip=state.clip;this.#info=undefined;this.#reason=undefined;if(state.bytes&&state.clip!==undefined)try{this.#info=inspectFrameEvents(state.bytes,state.clip);}catch(error){this.#reason=error.message;}}
  if(!this.#draft&&this.#info&&this.#selected>=this.#info.events.length)this.#selected=Math.max(0,this.#info.events.length-1);this.#view.render({info:this.#info,selected:this.#selected,draft:this.#draft,reason:this.#reason,clipName:state.clipName??''});
 }
 get draft(){return this.#draft;}set draft(value){this.#draft=value;}
 get barrier(){if(this.#dialog)return this.#dialog.barrier??=new Error('Finish or cancel the animation-event dialog before saving or changing the scene');}
 applyDraft(bytes){try{this.#validate('model-event-form');return editFrameEvents(bytes,{type:'update',clip:this.#options.state().clip,index:this.#selected,...this.#view.values()});}catch(error){this.#failure=error;throw error;}}
 async commit(bytes){try{await commitClipResource(this.#options.editor,this.#capture(),bytes);}catch(error){this.#failure=error;throw error;}}
 busy(value){this.#locked=value;this.#view.busy(value);}
}
