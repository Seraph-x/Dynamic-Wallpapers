import { inspectBonePose,inspectClips,bakeBoneDelta } from './model-api.mjs';
import { captureClipSource,commitClipResource } from './model-clip-edit.mjs';
import { initializeFkView } from './model-fk-view.mjs';
const $=id=>document.getElementById(id);
export class ModelFkTools {
 #options;#view;#dialog;#failure;
 constructor(options){
  this.#options=options;this.#view=initializeFkView(options.t,options.parent);
  const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void options.run(async()=>{try{await operation();}catch(error){this.#failure=error;this.#view.error(error.message);throw error;}});});
  bind('model-fk-open','click',async()=>{
   await options.prepare();const state=options.state(),info=inspectBonePose(state.bytes,{clip:state.clip,bone:state.bone,frame:0}),clip=inspectClips(state.bytes).clips.find(c=>c.id===state.clip);
   this.#dialog={source:captureClipSource(options.editor,state.id,state.bytes),bytes:state.bytes.slice(),bone:state.bone,clip,playback:{time:options.editor.controls.time,playing:options.editor.playing}};
   options.editor.setPlaying(false);this.#view.show({clip:clip.name,bone:state.boneName,frameCount:info.frameCount});
  });
  bind('model-fk-preview','click',async()=>{
   const target=this.#target(),values=this.#candidate(target,true);
   await options.editor.previewModelBonePose(target.source.id,{animation:target.clip.id,bone:target.bone,time:values.frame/target.clip.fps,delta:values.delta});this.#clear();
  });
  bind('model-fk-form','submit',async()=>{
   const target=this.#target(),{bytes}=this.#candidate(target,false);
   if(bytes.length!==target.bytes.length||bytes.some((value,i)=>value!==target.bytes[i]))await options.write(bytes,value=>commitClipResource(options.editor,target.source,value));
   await this.#restore(target);this.#release();this.#view.close();this.render();
  });
  bind('model-fk-cancel','click',()=>this.#cancel());
  $('model-fk-dialog').addEventListener('cancel',event=>{event.preventDefault();if(!$('model-fk-cancel').disabled)$('model-fk-cancel').click();});
  $('model-fk-form').addEventListener('input',()=>this.#clear());
 }
 #target(){const target=this.#dialog,state=this.#options.state();if(!target||target.source.document!==this.#options.editor.document||target.source.id!==state.id||target.source.path!==state.source?.path||target.source.version!==state.source?.version||target.bone!==state.bone||target.clip.id!==state.clip)throw new Error('Model or clip changed while the FK dialog was open');return target;}
 #candidate(target,preview){
  const inputs=[...$('model-fk-form').querySelectorAll('input')],disabled=inputs.map(input=>input.disabled);
  try{inputs.forEach(input=>input.disabled=false);if(!$('model-fk-form').checkValidity()){$('model-fk-form').reportValidity();throw new Error(inputs.find(input=>!input.validity.valid)?.validationMessage||'Invalid FK input');}}finally{inputs.forEach((input,i)=>input.disabled=disabled[i]);}
  const values=this.#view.values(),bytes=bakeBoneDelta(target.bytes,{clip:target.clip.id,bone:target.bone,...values});
  if(preview){if(values.frame<values.start||values.frame>values.end)throw new Error(this.#options.t.fkRangeError);if(target.clip.mode==='loop'&&values.frame===target.clip.frameCount)throw new Error(this.#options.t.fkLoopError);}
  return {...values,bytes};
 }
 async #restore(target){await this.#options.editor.restoreModelPreview(target.playback);}
 async #cancel(){const target=this.#dialog;if(!target)return;await this.#restore(target);this.#release();this.#view.close();this.render();}
 #clear(){if(this.#failure)this.#options.reset(this.#failure);this.#failure=undefined;this.#view.error('');}
 #release(){const barrier=this.#dialog?.barrier;this.#dialog=undefined;if(barrier)this.#options.reset(barrier);this.#clear();}
 get barrier(){if(this.#dialog)return this.#dialog.barrier??=new Error('Finish or cancel the FK dialog before saving or changing the scene');}
 render(){const state=this.#options.state();let available=false,reason;try{if(state.bytes&&state.clip!==undefined){inspectBonePose(state.bytes,{clip:state.clip,bone:state.bone,frame:0});available=true;}}catch(error){reason=error.message;}this.#view.render({available,reason:available?'':reason??this.#options.t.poseUnavailable});}
 busy(value){this.#view.busy(value);}
 destroy(){this.#release();this.#view.close();}
}
