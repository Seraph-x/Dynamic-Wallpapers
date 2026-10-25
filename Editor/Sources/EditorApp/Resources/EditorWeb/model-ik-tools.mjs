import { inspectIkChain,inspectClips,bakeTwoBoneIk } from './model-api.mjs';
import { captureClipSource,commitClipResource } from './model-clip-edit.mjs';
import { initializeIkView } from './model-ik-view.mjs';
const $=id=>document.getElementById(id);
export class ModelIkTools {
 #options;#view;#dialog;#failure;
 constructor(options){
  this.#options=options;this.#view=initializeIkView(options.t,options.parent);
  const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void options.run(async()=>{try{await operation();}catch(error){this.#failure=error;this.#view.error(error.message);throw error;}});});
  bind('model-ik-open','click',async()=>{
   await options.prepare();const state=options.state(),info=inspectIkChain(state.bytes,{clip:state.clip,bone:state.bone,frame:0}),clip=inspectClips(state.bytes).clips.find(c=>c.id===state.clip);
   this.#dialog={source:captureClipSource(options.editor,state.id,state.bytes),bytes:state.bytes.slice(),bone:state.bone,clip,playback:{time:options.editor.controls.time,playing:options.editor.playing}};options.editor.setPlaying(false);this.#view.show({info,bone:state.boneName,clip:clip.name});
  });
  bind('model-ik-preview','click',async()=>{const target=this.#target(),{preview,frame}=this.#candidate(target,true);await options.editor.previewModelBonePoses(target.source.id,{animation:target.clip.id,time:frame/target.clip.fps,poses:preview.poses});this.#clear();this.#view.preview(preview.residual);});
  bind('model-ik-form','submit',async()=>{
   const target=this.#target(),{bytes}=this.#candidate(target,false);
   if(bytes.length!==target.bytes.length||bytes.some((value,i)=>value!==target.bytes[i]))await options.write(bytes,value=>commitClipResource(options.editor,target.source,value));
   await options.editor.restoreModelPreview(target.playback);this.#release();this.#view.close();this.render();
  });
  bind('model-ik-cancel','click',()=>this.#cancel());$('model-ik-dialog').addEventListener('cancel',event=>{event.preventDefault();if(!$('model-ik-cancel').disabled)$('model-ik-cancel').click();});$('model-ik-form').addEventListener('input',()=>{this.#clear();this.#view.preview(undefined);});
 }
 #target(){const target=this.#dialog,state=this.#options.state();if(!target||target.source.document!==this.#options.editor.document||target.source.id!==state.id||target.source.path!==state.source?.path||target.source.version!==state.source?.version||target.bone!==state.bone||target.clip.id!==state.clip)throw new Error('Model or clip changed while the IK dialog was open');return target;}
 #candidate(target,preview){
  const inputs=[...$('model-ik-form').querySelectorAll('input')],disabled=inputs.map(input=>input.disabled);
  try{inputs.forEach(input=>input.disabled=false);if(!$('model-ik-form').checkValidity()){$('model-ik-form').reportValidity();throw new Error(inputs.find(input=>!input.validity.valid)?.validationMessage||'Invalid IK input');}}finally{inputs.forEach((input,i)=>input.disabled=disabled[i]);}
  const values=this.#view.values();
  if(preview){if(values.frame<values.start||values.frame>values.end)throw new Error(this.#options.t.fkRangeError);if(target.clip.mode==='loop'&&values.frame===target.clip.frameCount)throw new Error(this.#options.t.fkLoopError);}
  return {...bakeTwoBoneIk(target.bytes,{clip:target.clip.id,bone:target.bone,start:values.start,end:values.end,target:values.target,pole:values.pole,...(preview?{previewFrame:values.frame}:{})}),frame:values.frame};
 }
 async #cancel(){const target=this.#dialog;if(!target)return;await this.#options.editor.restoreModelPreview(target.playback);this.#release();this.#view.close();this.render();}
 #clear(){if(this.#failure)this.#options.reset(this.#failure);this.#failure=undefined;this.#view.error('');}
 #release(){const barrier=this.#dialog?.barrier;this.#dialog=undefined;if(barrier)this.#options.reset(barrier);this.#clear();}
 get barrier(){if(this.#dialog)return this.#dialog.barrier??=new Error('Finish or cancel the IK dialog before saving or changing the scene');}
 render(){const state=this.#options.state();let available=false,message;try{if(state.bytes&&state.clip!==undefined){inspectIkChain(state.bytes,{clip:state.clip,bone:state.bone,frame:0});available=true;}}catch(error){message=error.message;}this.#view.render({available,message:available?'':message??this.#options.t.ikUnavailable});}
 busy(value){this.#view.busy(value);}
 destroy(){this.#release();this.#view.close();}
}
