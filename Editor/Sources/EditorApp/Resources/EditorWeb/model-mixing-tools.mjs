import { inspectModel } from './model-api.mjs';
import { inspectMixLayers,editMixLayers } from './model-mixing.mjs';
import { captureClipSource,commitClipLayers,commitClipResource } from './model-clip-edit.mjs';
import { initializeMixingView } from './model-mixing-view.mjs';
const $=id=>document.getElementById(id);
export class ModelMixingTools {
 #options;#view;#selected=0;#draft=false;#failure;#source;#dialog;#context;#locked=false;
 constructor(options){
  this.#options=options;this.#view=initializeMixingView(options.t,options.parent);
  const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void options.run(async()=>{try{await operation();}catch(error){this.#failure=error;throw error;}});});
  $('model-mix-form').addEventListener('input',()=>{try{if(!this.#draft)this.#source=this.#capture();this.#draft=true;this.#clear();}catch(error){this.#failure=error;void options.run(()=>{throw error;});}});
  bind('model-mix-form','submit',()=>options.prepare());
  bind('model-mix-revert','click',()=>{this.#draft=false;this.#source=undefined;this.#clear();this.render();});
  bind('model-mix-select','change',async()=>{const index=Number($('model-mix-select').value);try{await options.prepare();if(!this.#info().rows[index])throw new Error('Animation layer is unavailable');this.#selected=index;}finally{this.render();}});
  bind('model-mix-add','click',async()=>{const clip=Number($('model-mix-add-clip').value);await options.prepare();await this.#edit({type:'add',clip,name:options.t.mixNewName},this.#info().rows.length);});
  bind('model-mix-duplicate','click',async()=>{await options.prepare();await this.#edit({type:'duplicate',index:this.#selected},this.#selected+1);});
  for(const [id,delta] of [['up',-1],['down',1]])bind('model-mix-'+id,'click',async()=>{await options.prepare();await this.#edit({type:'move',index:this.#selected,to:this.#selected+delta},this.#selected+delta);});
  bind('model-mix-remove','click',async()=>{await options.prepare();const info=this.#info(),source=this.#capture();this.#dialog={source,index:this.#selected};this.#view.showRemove(info.rows[this.#selected],info.rows.length===1);});
  bind('model-mix-remove-form','submit',async()=>{const target=this.#dialog;if(!target)throw new Error('Animation-layer removal is unavailable');const table=editMixLayers(this.#table(target.source.snapshot,target.source.id),{type:'remove',index:target.index},options.state().clips);await commitClipLayers(options.editor,target.source,table);this.#close();this.render();});
  $('model-mix-remove-cancel').addEventListener('click',()=>{if(!this.#locked)this.#close();});const dialog=$('model-mix-remove-dialog');dialog.addEventListener('cancel',e=>{e.preventDefault();if(!this.#locked)this.#close();});dialog.addEventListener('close',()=>{if(!dialog.open&&this.#dialog)this.#release();});
 }
 #capture(){const state=this.#options.state();return captureClipSource(this.#options.editor,state.id,state.bytes);}
 #table(snapshot=this.#options.editor.document.snapshot(),id=this.#options.state().id){return snapshot.scene.objects?.find(row=>row.id===id)?.animationlayers;}
 #info(){return inspectMixLayers(this.#table(),this.#options.state().clips);}
 #clear(){if(this.#failure)this.#options.reset(this.#failure);this.#failure=undefined;}
 #release(){const barrier=this.#dialog?.barrier;this.#dialog=undefined;if(barrier)this.#options.reset(barrier);this.#clear();}
 #close(){this.#release();this.#view.close();}
 async #edit(operation,next){const source=this.#capture(),table=editMixLayers(this.#table(source.snapshot,source.id),operation,this.#options.state().clips),previous=this.#selected;try{this.#selected=next;await commitClipLayers(this.#options.editor,source,table);this.#clear();}catch(error){this.#selected=previous;throw error;}finally{this.render();}}
 render(){const state=this.#options.state(),context=[state.source?.document,state.id,state.source?.path];if(!this.#draft&&(!this.#context||context.some((v,i)=>v!==this.#context[i])))this.#selected=0;this.#context=context;const info=this.#info();if(!this.#draft&&this.#selected>=info.rows.length)this.#selected=Math.max(0,info.rows.length-1);this.#view.render(info,this.#selected,state.clips,this.#draft);}
 get draft(){return this.#draft;}set draft(value){this.#draft=value;}
 get barrier(){if(this.#dialog)return this.#dialog.barrier??=new Error('Finish or cancel the animation-layer dialog before saving or changing the scene');}
 applyDraft(bytes){try{const form=$('model-mix-form'),controls=[...form.querySelectorAll('fieldset,input,select')],disabled=controls.map(e=>e.disabled);try{controls.forEach(e=>e.disabled=false);if(!form.checkValidity()){if(!document.body.inert)form.reportValidity();throw new Error(form.querySelector('input:invalid,select:invalid')?.validationMessage||'Invalid animation-layer input');}}finally{controls.forEach((e,i)=>e.disabled=disabled[i]);}
   const clips=bytes===this.#options.state().bytes?this.#options.state().clips:inspectModel(bytes).animations;
   return editMixLayers(this.#table(this.#source.snapshot,this.#source.id),{type:'update',index:this.#selected,values:this.#view.values()},clips);
  }catch(error){this.#failure=error;throw error;}}
 async commit(table,bytes){try{const source=this.#source??this.#capture();if(bytes)await commitClipResource(this.#options.editor,source,bytes,{animationLayers:table});else await commitClipLayers(this.#options.editor,source,table);this.#source=undefined;this.#clear();}catch(error){this.#failure=error;throw error;}}
 busy(value){this.#locked=value;this.#view.busy(value);}
}
