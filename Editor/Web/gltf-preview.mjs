import { createScene } from './webwallgl.bundle.mjs';
import { editorOf } from './editor-api.mjs';
import { createEditorSource,createWorkbenchScene } from './runtime.mjs';
import { observeModelCapacity } from './model-capacity.mjs';
import { captureGltfPreview } from './gltf-import-edit.mjs';
import { validateGltfRender } from './model-api.mjs';
export class GltfPreview {
 #instance;#observer;#canvas;#sequence=0;#element;
 constructor(element){this.#element=element;}
 async load(candidate){
  this.destroy();const sequence=this.#sequence,canvas=document.createElement('canvas');this.#canvas=canvas;this.#element.replaceChildren(canvas);this.#observer=observeModelCapacity(canvas);
  const files=new Map(candidate.files.map(file=>[file.path,file.data.slice()])),b=candidate.bounds,width=Math.max(1,b[3]-b[0])*1.3,height=Math.max(1,b[4]-b[1])*1.3;
  const snapshot={title:'Model preview',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{general:{orthogonalprojection:{width,height},clearcolor:'0.09 0.10 0.11',clearenabled:true,cameraparallax:false},objects:[{id:1,name:'Model preview',model:candidate.mdlPath,origin:`${width/2-(b[0]+b[3])/2} ${height/2-(b[1]+b[4])/2} ${-(b[2]+b[5])/2}`,scale:'1 1 1',angles:'0 0 0',visible:true}]}};
  let failure;const zero=new Float32Array(64),instance=createWorkbenchScene(createScene,canvas,{fps:30,fit:'contain',volume:0,audio:{snapshot:()=>({left:zero,right:zero})},media:null,autoQuality:false,debugHooks:false,onError:error=>{failure=error;},onDiagnostic:(message,level)=>{if(level==='error')failure=new Error(message);else if(level==='warn')console.warn(message);}});this.#instance=instance;
  try{
   await instance.load(createEditorSource(snapshot,async path=>files.get(path)??null,async()=>{throw new Error('Unexpected model preview version request');}));
   if(sequence!==this.#sequence)throw new Error('Model preview was replaced');
   if(failure)throw failure;const controls=editorOf(instance);validateGltfRender(candidate,controls?.getModelInfo(1));controls.setTimeScale(0);await controls.seek(0);if(failure)throw failure;
   if(this.#observer.error)throw this.#observer.error;
   const receipt=captureGltfPreview(candidate,this.#observer.capacity);this.#observer.dispose();return receipt;
  }catch(error){if(sequence===this.#sequence)this.destroy();throw error;}
 }
 destroy(){this.#sequence++;this.#observer?.dispose();this.#observer=undefined;this.#instance?.destroy({releasePkgCache:true});this.#instance=undefined;this.#canvas?.remove();this.#canvas=undefined;}
}
