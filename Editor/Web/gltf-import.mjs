import { parseGltfSource,buildGltfModel,prepareGltfCandidate } from './model-api.mjs';
import { captureGltfDocument,commitGltfImport } from './gltf-import-edit.mjs';
import { decodeResource } from './resources.mjs';
import { initializeGltfImportView } from './gltf-import-view.mjs';
import { GltfPreview } from './gltf-preview.mjs';
export class GltfImport {
 #editor;#t;#view;#preview;#capture;#source;#candidate;#receipt;#barrier;#failure;#busy=false;#locked=false;#closed=false;#onError;#onClose;#onImported;
 constructor({editor,t,onError,onClose,onImported}){
  this.#editor=editor;this.#t=t;this.#onError=onError;this.#onClose=onClose;this.#onImported=onImported;this.#view=initializeGltfImportView(t);this.#preview=new GltfPreview(this.#view.preview);
  this.#view.form.addEventListener('submit',event=>{event.preventDefault();if(!this.#view.valid())return;void this.#commit();});
  document.getElementById('gltf-update').addEventListener('click',()=>{void this.#prepare();});
  document.getElementById('gltf-cancel').addEventListener('click',()=>{if(!this.#busy&&!this.#locked)this.#close();});
  this.#view.dialog.addEventListener('cancel',event=>{event.preventDefault();if(!this.#busy&&!this.#locked)this.#close();});
  this.#view.dialog.addEventListener('close',()=>{if(!this.#view.dialog.open)this.#clear();});
  for(const element of Object.values(this.#view.inputs))element.addEventListener('input',()=>{this.#receipt=undefined;this.#view.error('');});
 }
 #clear(){if(!this.#source)return;const barrier=this.#barrier,failure=this.#failure;this.#preview.destroy();this.#source=undefined;this.#candidate=undefined;this.#receipt=undefined;this.#capture=undefined;this.#barrier=undefined;this.#failure=undefined;this.#onClose(barrier,failure);}
 #close(){this.#clear();this.#view.close();}
 async open(value){
  if(this.#closed||this.#locked||this.#editor.frozen||this.#source)throw new Error(this.#t.gltfPending);
  if(!value||typeof value.entry!=='string'||!Array.isArray(value.files)||Object.keys(value).some(k=>!['entry','files'].includes(k)))throw new Error('Invalid model import source');
  const source=parseGltfSource({entry:value.entry,files:value.files.map(file=>{if(!file||Object.keys(file).some(k=>!['path','data'].includes(k)))throw new Error('Invalid model import file');return {path:file.path,bytes:decodeResource(file.data)};})});
  const scenes=source.json.scenes??[];if(!Array.isArray(scenes)||scenes.some(scene=>!scene||typeof scene!=='object'||Array.isArray(scene)||(scene.name!==undefined&&typeof scene.name!=='string')))throw new Error('Invalid glTF scene metadata');
  if(source.json.scene!==undefined&&(!Number.isSafeInteger(source.json.scene)||source.json.scene<0||source.json.scene>=scenes.length))throw new Error('Invalid glTF default scene');
  this.#capture=captureGltfDocument(this.#editor);this.#source=source;this.#barrier=new Error(this.#t.gltfPending);
  try{this.#view.show(source,this.#capture.snapshot);}catch(error){this.#clear();throw error;}await this.#prepare();
 }
 #setBusy(value){this.#busy=value;this.#view.busy(value,this.#locked);}
 async #prepare(){
  if(this.#busy||this.#locked||!this.#source)return;
  for(const input of Object.values(this.#view.inputs))if(!input.reportValidity())return;
  this.#setBusy(true);this.#receipt=undefined;this.#view.error(this.#t.gltfBusy);
  try{
   const options=this.#view.values(),model=buildGltfModel(this.#source,{identifier:crypto.randomUUID(),...options}),candidate=await prepareGltfCandidate(model);
   if(this.#closed||!this.#source)throw new Error('Model import closed during preparation');
   this.#receipt=await this.#preview.load(candidate);this.#candidate=candidate;this.#view.ready(candidate);this.#view.error('');this.#onClose(this.#failure);this.#failure=undefined;
  }catch(error){this.#failure=error;this.#view.error(error.message);this.#onError(error);}finally{this.#setBusy(false);}
 }
 async #commit(){
  if(this.#busy||this.#locked||!this.#source)return;
  if(!this.#receipt){this.#view.error(this.#t.gltfUnavailable);return;}
  this.#setBusy(true);this.#view.error('');
  try{
   const options=this.#view.values(),result=await commitGltfImport(this.#editor,this.#capture,this.#candidate,{name:options.name,origin:options.origin,allowUnlit:this.#view.consent.checked,preview:this.#receipt});
   this.#close();await this.#onImported(result.id);
  }catch(error){this.#failure=error;this.#view.error(error.message);this.#onError(error);}finally{this.#setBusy(false);}
 }
 get error(){return this.#barrier;}
 setFrozen(value){this.#locked=value;this.#view.busy(this.#busy,value);}
 destroy(){this.#closed=true;this.#preview.destroy();}
}
