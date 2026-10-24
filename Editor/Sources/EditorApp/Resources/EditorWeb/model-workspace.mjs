import { inspectModel,editModelHierarchy,setSkinInfluences,captureImageSource,commitImagePuppet } from './model-api.mjs';
import { modelResourceSource,commitModelResource } from './model-resource-edit.mjs';
import { initializeModelView } from './model-view.mjs';
import { ModelBoneOverlay,drawWeightMap } from './model-overlay.mjs';

const $=id=>document.getElementById(id);
export class ModelWorkspace {
  #editor;#t;#error;#reset;#view;#overlay;#active=false;#id;#source;#bytes;#data;#bone=0;#mesh=0;#vertex=0;#points;
  #boneDraft=false;#weightDraft=false;#failure;#loadError;#operations=Promise.resolve();#loading=Promise.resolve({ok:true});#loadRevision=0;#busy=0;#closed=false;#locked=false;#dialogTarget;#imageSource;
  constructor({editor,t,onError,onResetInput}) {
    this.#editor=editor;this.#t=t;this.#error=onError;this.#reset=onResetInput;this.#view=initializeModelView(t);
    const bind=(id,event,operation)=>$(id).addEventListener(event,e=>{e.preventDefault();void this.#run(()=>operation(e));});
    bind('model-workspace','click',async()=>{await this.#prepare();this.#active=true;this.#toggle();this.update(editor.document,this.#id,true);await this.#loading;});
    bind('properties-workspace','click',async()=>{await this.#prepare();this.#active=false;this.#toggle();});
    const draft=(kind)=>{if(kind==='bone')this.#boneDraft=true;else this.#weightDraft=true;this.#failure=undefined;this.#reset();};
    $('model-bone-form').addEventListener('input',()=>draft('bone'));
    $('model-weights-form').addEventListener('input',event=>{if(!['model-vertex','model-skin-mesh'].includes(event.target.id))draft('weight');});
    bind('model-bone-form','submit',()=>this.#prepare());bind('model-weights-form','submit',()=>this.#prepare());
    for(const id of ['model-bone-revert','model-weights-revert'])bind(id,'click',()=>{this.#boneDraft=false;this.#weightDraft=false;this.#failure=undefined;this.#reset();this.#render();});
    bind('model-recover','click',()=>{this.#boneDraft=false;this.#weightDraft=false;this.#failure=undefined;this.#reset();this.#render(false,this.#loadError?.message);});
    bind('model-reload','click',()=>{this.#failure=undefined;this.#reset();this.update(editor.document,this.#id,true);});
    bind('model-create','click',async()=>{await this.#prepare();this.#dialogTarget={source:this.#source,bone:this.#bone};this.#view.showCreate(this.#data,this.#bone);});
    bind('model-delete','click',async()=>{await this.#prepare();this.#dialogTarget={source:this.#source,bone:this.#bone};this.#view.showDelete(this.#data,this.#bone,this.#impact());});
    bind('model-image-create','click',async()=>{await this.#prepare();this.#imageSource=captureImageSource(editor,this.#id);this.#view.showImage();});
    bind('model-image-dialog-form','submit',async()=>{
      this.#validate('model-image-dialog-form');this.#view.imageError('');
      try{
        await commitImagePuppet(editor,this.#imageSource,this.#view.imageValues());this.#bone=0;this.#mesh=0;this.#vertex=0;
        this.#failure=undefined;this.#reset();await this.#loading;this.#render();this.#view.closeImage();
      }catch(error){this.#view.imageError(error.message);throw error;}
    });
    for(const [cancel,dialog] of [['model-new-cancel','model-create-dialog'],['model-delete-cancel','model-delete-dialog'],['model-image-cancel','model-image-dialog']]){
      $(cancel).addEventListener('click',()=>{if(!this.#locked&&!this.#busy)$(dialog).close();});
      $(dialog).addEventListener('cancel',event=>{if(this.#busy||this.#locked)event.preventDefault();});
      $(dialog).addEventListener('close',()=>{this.#dialogTarget=undefined;this.#imageSource=undefined;this.#failure=undefined;this.#reset();});
    }
    bind('model-create-dialog-form','submit',async()=>{
      this.#validate('model-create-dialog-form');this.#assertDialog();const pose=[];
      for(const prefix of ['t','r','s'])for(const axis of ['x','y','z'])pose.push($(`model-new-${prefix}${axis}`).valueAsNumber*(prefix==='r'?Math.PI/180:1));
      const edit={type:'create',parent:Number($('model-new-parent').value),name:$('model-new-name').value,pose};
      await this.#hierarchy(edit);$('model-create-dialog').close();
    });
    bind('model-delete-dialog-form','submit',async()=>{
      this.#validate('model-delete-dialog-form');this.#assertDialog();const value=$('model-delete-replacement').value;
      await this.#hierarchy({type:'delete',bone:this.#dialogTarget.bone,...(value===''?{}:{replacement:Number(value)})});$('model-delete-dialog').close();
    });
    for(const id of ['model-skin-mesh','model-vertex']){
      $(id).addEventListener('change',()=>{
        const mesh=Number($('model-skin-mesh').value),vertex=id==='model-skin-mesh'?0:$('model-vertex').valueAsNumber;
        void this.#run(async()=>{await this.#prepare();const count=this.#data?.meshes[mesh]?.vertexCount;
          if(!Number.isInteger(vertex)||vertex<0||(count&&vertex>=count))throw new Error('Invalid vertex selection');
          this.#mesh=mesh;this.#vertex=vertex;this.#render();});
      });
    }
    $('model-weight-map').addEventListener('click',event=>{
      if(!this.#points?.length)return;const box=event.currentTarget.getBoundingClientRect(),x=(event.clientX-box.left)*320/box.width,y=(event.clientY-box.top)*180/box.height;
      let vertex=0,distance=Infinity;this.#points.forEach((point,i)=>{const d=Math.hypot(point[0]-x,point[1]-y);if(d<distance){distance=d;vertex=i;}});
      void this.#run(async()=>{await this.#prepare();this.#vertex=vertex;this.#render();});
    });
    $('model-weight-map').addEventListener('keydown',event=>{
      if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End'].includes(event.key))return;event.preventDefault();
      const count=this.#data?.meshes[this.#mesh]?.vertexCount;if(!count)return;
      const vertex=event.key==='Home'?0:event.key==='End'?count-1:Math.max(0,Math.min(count-1,this.#vertex+(['ArrowLeft','ArrowDown'].includes(event.key)?-1:1)));
      void this.#run(async()=>{await this.#prepare();this.#vertex=vertex;this.#render();});
    });
    this.#overlay=new ModelBoneOverlay({svg:$('model-bone-overlay'),editor,state:()=>({visible:this.#active&&Boolean(this.#data)&&$('model-show-bones').checked,id:this.#id,bone:this.#bone}),onSelect:i=>this.#selectBone(i)});
    this.#toggle();
  }
  #run(operation,preparation=false) {
    const accepted=preparation||(!this.#locked&&!this.#editor.frozen);
    this.#busy++;this.#view.busy(true);
    const result=this.#operations.then(()=>{if(!accepted)throw new Error('Editor is frozen');return operation();});this.#operations=result.catch(()=>{});
    void result.catch(error=>{this.#failure=error;this.#error(error);}).finally(()=>{this.#busy--;this.#view.busy(this.#busy>0||this.#locked);});return result;
  }
  #toggle() {
    $('model-panel').hidden=!this.#active;$('property-panel').hidden=this.#active;$('binding').hidden=this.#active;
    $('model-workspace').setAttribute('aria-pressed',String(this.#active));$('properties-workspace').setAttribute('aria-pressed',String(!this.#active));
    $('properties-heading').textContent=this.#active?this.#t.modelWorkspace:this.#t.properties;
  }
  update(document,id,force=false) {
    this.#id=id;if(!this.#active)return;
    let source;
    try{
      if(!this.#editor.controls?.getModelInfo(id)){this.#loadRevision++;this.#data=undefined;this.#source=undefined;this.#loadError=undefined;this.#loading=Promise.resolve({ok:true});this.#render();return;}
      source=modelResourceSource(this.#editor,id);
    }catch(error){this.#loadRevision++;this.#data=undefined;this.#source=undefined;this.#loadError=error;this.#loading=Promise.resolve({ok:false,error});this.#render(false,error.message);this.#error(error);return;}
    if(!force&&this.#source?.document===document&&this.#source.id===id&&this.#source.path===source.path&&this.#source.version===source.version){this.#render();return;}
    const loadRevision=++this.#loadRevision;
    if((this.#boneDraft||this.#weightDraft)&&this.#source)this.#failure=new Error('Model changed while inputs were pending; revert them before continuing');
    const hadLoadError=Boolean(this.#loadError);
    this.#source=source;this.#data=undefined;this.#bytes=undefined;this.#loadError=undefined;this.#render(true);
    const loading=this.#editor.readResource(source.path).then(bytes=>{
      if(loadRevision!==this.#loadRevision||this.#closed)return;
      if(!bytes)throw new Error('The selected model resource is missing');
      this.#bytes=bytes;this.#data=inspectModel(bytes);this.#bone=Math.min(this.#bone,this.#data.bones.length-1);this.#mesh=Math.min(this.#mesh,this.#data.meshes.length-1);
      this.#vertex=Math.min(this.#vertex,(this.#data.meshes[this.#mesh]?.vertexCount??1)-1);if(hadLoadError)this.#reset();this.#render();
    });
    this.#loading=loading.then(()=>({ok:true}),error=>{
      if(loadRevision===this.#loadRevision){this.#loadError=error;this.#render(false,error.message);this.#error(error);}
      return {ok:false,error}; // Failed inspection is an explicit read-only state, not an accepted edit.
    });
  }
  #render(loading=false,error) {
    if(!this.#active)return;let capacity;
    try{capacity=this.#editor.modelBoneCapacity;}catch(value){error=value.message;}
    const layer=this.#editor.document.snapshot().scene.objects?.find(layer=>layer.id===this.#id);
    const canCreateImage=!this.#source&&!this.#loadError&&typeof layer?.image==='string'&&layer.text===undefined&&layer.model===undefined;
    this.#view.render({data:this.#data,bone:this.#bone,mesh:this.#mesh,vertex:this.#vertex,capacity,boneDraft:this.#boneDraft,weightDraft:this.#weightDraft,onBone:i=>this.#selectBone(i),loading,error:error??this.#loadError?.message,canCreateImage});
    if(this.#data)this.#points=drawWeightMap($('model-weight-map'),this.#data.meshes[this.#mesh],this.#bone,this.#vertex);
    this.#view.busy(this.#busy>0||this.#locked);
  }
  #selectBone(bone){void this.#run(async()=>{await this.#prepare();this.#bone=bone;this.#render();});}
  #validate(id) {
    const form=$(id),controls=[...form.querySelectorAll('fieldset,input,select')],states=controls.map(input=>input.disabled);
    try{
      controls.forEach(input=>{input.disabled=false;});if(form.checkValidity())return;
      const message=form.querySelector('input:invalid,select:invalid')?.validationMessage??'Invalid model input';
      if(!document.body.inert)form.reportValidity();throw new Error(message);
    }finally{controls.forEach((input,i)=>{input.disabled=states[i];});}
  }
  #assertDialog() {
    const source=this.#dialogTarget?.source;
    if(!source||source.document!==this.#editor.document||source.id!==this.#id||source.path!==this.#source?.path||source.version!==this.#source?.version)throw new Error('Model changed while the dialog was open');
  }
  async #write(bytes,map,created=false) {
    const source=this.#source,previous=this.#bone;
    await commitModelResource(this.#editor,source,bytes);
    if(created)this.#bone=inspectModel(bytes).bones.length-1;else if(map)this.#bone=map[previous]>=0?map[previous]:0;
    this.#failure=undefined;this.#reset();await this.#loading;this.#render();
  }
  async #hierarchy(edit) {
    if(!this.#source||!this.#bytes)throw new Error('Select a readable model');
    const result=editModelHierarchy(this.#bytes,{...edit,boneLimit:this.#editor.modelBoneCapacity});
    await this.#write(result.bytes,result.oldToNew,edit.type==='create');
  }
  #impact() {
    let vertices=0;
    for(const mesh of this.#data.meshes){if(mesh.error)throw new Error(mesh.error);
      for(let i=0;i<mesh.vertexCount;i++)if([0,1,2,3].some(k=>mesh.joints[i*4+k]===this.#bone&&mesh.weights[i*4+k]>0))vertices++;
    }
    return {vertices,attachments:this.#data.attachments.filter(a=>a.bone===this.#bone).length,children:this.#data.bones.filter(b=>b.parent===this.#bone).length};
  }
  async #prepare() {
    const loaded=await this.#loading;
    if(!loaded.ok&&(this.#boneDraft||this.#weightDraft))throw loaded.error;
    if(this.#failure)throw this.#failure;
    if(!this.#boneDraft&&!this.#weightDraft)return;
    const boneDraft=this.#boneDraft,weightDraft=this.#weightDraft;let bytes=this.#bytes,map;
    if(this.#weightDraft){
      this.#validate('model-weights-form');const influences=[];
      for(let i=0;i<4;i++){
        const joint=$(`model-joint-${i}`).value,weight=$(`model-weight-${i}`).valueAsNumber;
        if(joint!=='')influences.push({joint:Number(joint),weight});else if(weight!==0)throw new Error('Unused joint must have zero weight');
      }
      bytes=setSkinInfluences(bytes,{mesh:this.#mesh,edits:[{vertex:this.#vertex,influences}],boneLimit:this.#editor.modelBoneCapacity});
    }
    if(this.#boneDraft){
      this.#validate('model-bone-form');const name=$('model-bone-name').value,parent=Number($('model-bone-parent').value),bone=this.#bone;
      bytes=editModelHierarchy(bytes,{type:'rename',bone,name}).bytes;
      if(parent!==this.#data.bones[bone].parent){const result=editModelHierarchy(bytes,{type:'reparent',bone,parent,boneLimit:this.#editor.modelBoneCapacity});bytes=result.bytes;map=result.oldToNew;}
    }
    // Weights use the original bone IDs, then hierarchy mapping reindexes them.
    // Both forms publish one resource revision so combined drafts undo together.
    this.#boneDraft=false;this.#weightDraft=false;
    try{await this.#write(bytes,map);}catch(error){this.#boneDraft=boneDraft;this.#weightDraft=weightDraft;throw error;}
  }
  flush(){return this.#run(async()=>{if(document.querySelector('.model-dialog[open]'))throw new Error('Finish or cancel the model dialog before saving or changing the scene');await this.#prepare();},true);}
  setFrozen(value){this.#locked=value;this.#view.busy(value||this.#busy>0);}
  destroy(){this.#closed=true;this.#loadRevision++;this.#overlay.destroy();}
}
