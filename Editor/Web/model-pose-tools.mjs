import { inspectBonePose,editBonePose } from './model-api.mjs';
import { captureClipSource,commitClipResource } from './model-clip-edit.mjs';
import { initializePoseView } from './model-pose-view.mjs';
const $=id=>document.getElementById(id);
export class ModelPoseTools {
 #options;#view;#frame=0;#draft=false;#failure;#clipboard;#context;
 constructor(options){
  this.#options=options;this.#view=initializePoseView(options.t,options.parent);
  const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void options.run(async()=>{try{await operation();}catch(error){this.#failure=error;throw error;}});});
  $('model-pose-form').addEventListener('input',()=>{this.#draft=true;this.#clear();});
  bind('model-pose-form','submit',()=>options.prepare());
  bind('model-pose-revert','click',()=>{this.#draft=false;this.#clear();this.render();});
  bind('model-pose-frame','change',async()=>{const frame=$('model-pose-frame').valueAsNumber;try{await options.prepare();this.#inspect(options.state().bytes,frame);this.#frame=frame;}finally{this.render();}});
  bind('model-pose-copy','click',async()=>{await options.prepare();this.#clipboard=[...this.#inspect(options.state().bytes).pose];this.render();});
  bind('model-pose-paste','click',async()=>{await options.prepare();if(!this.#clipboard)throw new Error('Copy a bone pose first');this.#view.setPose(this.#clipboard);this.#draft=true;this.#clear();});
  bind('model-pose-reset','click',async()=>{await options.prepare();await this.#edit({type:'reset'});});
  bind('model-pose-preview','click',async()=>{await options.prepare();const info=this.#inspect(options.state().bytes);await options.editor.previewModelClip(options.state().id,info.clip,info.time);});
  bind('model-pose-range-form','submit',async()=>{this.#validate('model-pose-range-form');await options.prepare();await this.#edit({type:'interpolate',...this.#view.range()});});
 }
 #selection(bone=this.#options.state().bone){return {clip:this.#options.state().clip,bone,frame:this.#frame};}
 #inspect(bytes,frame=this.#frame){return inspectBonePose(bytes,{...this.#selection(),frame});}
 #clear(){if(this.#failure)this.#options.reset(this.#failure);this.#failure=undefined;}
 #validate(id){const form=$(id),controls=[...form.querySelectorAll('fieldset,input')],disabled=controls.map(i=>i.disabled);try{controls.forEach(i=>i.disabled=false);if(form.checkValidity())return;if(!document.body.inert)form.reportValidity();throw new Error(form.querySelector('input:invalid')?.validationMessage??'Invalid pose input');}finally{controls.forEach((input,i)=>input.disabled=disabled[i]);}}
 async #edit(operation){const bytes=editBonePose(this.#options.state().bytes,{...this.#selection(),...operation});await this.#options.write(bytes,value=>this.commit(value));}
 render(){
  const state=this.#options.state(),context=[state.source?.document,state.id,state.source?.path,state.bone,state.clip];
  if(!this.#draft&&(!this.#context||context.some((value,i)=>value!==this.#context[i])))this.#frame=0;
  this.#context=context;let info,reason;
  if(state.bytes&&state.clip!==undefined)try{
   const first=this.#inspect(state.bytes,0);
   // Resizing may remove the inspected sample; only selection returns to zero.
   if(!this.#draft&&this.#frame>first.frameCount)this.#frame=0;
   info=this.#frame===0?first:this.#inspect(state.bytes);
  }catch(error){reason=error.message;}
  this.#view.render({info,draft:this.#draft,reason,bone:state.boneName??'',hasClipboard:Boolean(this.#clipboard)});
 }
 get draft(){return this.#draft;}set draft(value){this.#draft=value;}
 applyDraft(bytes,bone){try{this.#validate('model-pose-form');return editBonePose(bytes,{type:'set',...this.#selection(bone),pose:this.#view.values()});}catch(error){this.#failure=error;throw error;}}
 async commit(bytes){try{const state=this.#options.state(),source=captureClipSource(this.#options.editor,state.id,state.bytes);await commitClipResource(this.#options.editor,source,bytes);}catch(error){this.#failure=error;throw error;}}
 busy(value){this.#view.busy(value);}
}
