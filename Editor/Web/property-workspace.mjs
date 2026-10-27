import { createPropertyCatalog } from './property-catalog.mjs';
import { PropertyWorkspaceView } from './property-workspace-view.mjs';

const defaults={bool:false,slider:0,color:'1 1 1',textinput:'',combo:''};
export class PropertyWorkspace {
  #editor;#t;#view;#onError;#reset;#onDraft;#row;#name;#rows=[];#dirty=false;#creating=false;#copy=false;
  #failure;#operations=Promise.resolve();#busy=0;#locked=false;#closed=false;#deleteName;
  constructor({editor,t,onError,onResetInput,onDraftChange,beforeEdit}){
    this.#editor=editor;this.#t=t;this.#onError=onError;this.#reset=onResetInput;this.#onDraft=onDraftChange;this.#view=new PropertyWorkspaceView(t);
    const bind=(name,operation)=>document.getElementById('user-property-'+name).addEventListener('click',()=>void this.#run(operation));
    bind('new',async()=>{await beforeEdit();await this.#commit();this.#start();});
    bind('copy',async()=>{await beforeEdit();await this.#commit();this.#start(this.#row);});
    bind('delete',async()=>{await beforeEdit();await this.#commit();this.#deleteName=this.#name;document.getElementById('user-property-delete-name').textContent=this.#deleteName;this.#view.dialog.showModal();});
    bind('delete-cancel',()=>{this.#view.dialog.close();this.#deleteName=undefined;this.#clear();});
    bind('delete-confirm',async()=>{
      if(!this.#view.dialog.open||this.#deleteName===undefined)throw new Error(this.#t.propertyPending);
      const name=this.#deleteName;
      await editor.change(doc=>doc.propertyDefinition({type:'delete',name}));
      this.#view.dialog.close();this.#deleteName=undefined;this.#clear();this.update(editor.document);
    });
    this.#view.dialog.addEventListener('cancel',event=>{if(this.#locked||this.#busy)event.preventDefault();else this.#clear();});
    this.#view.list.addEventListener('change',()=>{const name=this.#view.list.value;this.#view.list.value=this.#name??'';void this.#run(async()=>{await beforeEdit();await this.#commit();this.#name=name;this.update(editor.document);});});
    this.#view.form.addEventListener('input',event=>{
      if(this.#locked||this.#busy||editor.frozen)return;
      this.#dirty=true;this.#clear();
      if(event.target.name?.startsWith('option-'))this.#view.optionInput();
      this.#onDraft();
    });
    this.#view.form.addEventListener('change',event=>{
      if(event.target.id==='user-property-type'&&this.#creating&&!this.#copy){
        const type=event.target.value;this.#view.typeFields({type,value:defaults[type],...(type==='combo'?{options:[{label:'',value:''}]}:{})});this.#dirty=true;this.#onDraft();
      }
    });
    this.#view.form.addEventListener('submit',event=>{event.preventDefault();void this.#run(async()=>{await beforeEdit();await this.#commit();});});
    this.#view.form.addEventListener('click',event=>{
      const id=event.target.closest('button')?.id;
      if(id==='user-property-revert')void this.#run(()=>{this.#dirty=false;this.#creating=false;this.#clear();this.update(editor.document);this.#onDraft();});
      if(id==='user-property-add-option'||id?.startsWith('user-property-remove-option-')){
        if(this.#locked||this.#busy||editor.frozen)return;
        this.#view.optionChange(id==='user-property-add-option'?undefined:Number(id.slice('user-property-remove-option-'.length)));this.#dirty=true;this.#clear();this.#onDraft();
      }
    });
  }
  get dirty(){return this.#dirty;}
  get error(){return this.#failure;}
  get hasPendingInput(){return this.#dirty||Boolean(this.#failure)||this.#busy>0||this.#view.dialog.open;}
  #clear(){const previous=this.#failure;this.#failure=undefined;this.#view.error('');if(previous)this.#reset(previous);}
  #fail(error){this.#failure=error;this.#view.error(error.message);this.#onError(error);}
  #run(operation){
    const accepted=!this.#locked&&!this.#editor.frozen&&!this.#closed;this.#busy++;this.#view.panel.inert=true;this.#dialogBusy();
    const result=this.#operations.then(async()=>{if(!accepted)throw new Error('Editor is closed or frozen');return operation();});
    this.#operations=result.catch(()=>{});
    void result.catch(error=>this.#fail(error)).finally(()=>{
      this.#busy--;this.#view.panel.inert=this.#busy>0||this.#locked;this.#dialogBusy();
      if(this.#view.dialog.open&&!this.#busy&&!this.#locked)document.getElementById('user-property-delete-cancel').focus();
    });return result;
  }
  #dialogBusy(){for(const button of this.#view.dialog.querySelectorAll('button'))button.disabled=this.#busy>0||this.#locked;}
  #start(source){
    this.#creating=true;this.#copy=Boolean(source);this.#dirty=true;
    this.#row=source??{name:'',type:'bool',value:false};this.#view.show(this.#row,{creating:true,copy:this.#copy});this.#onDraft();document.getElementById('user-property-key').focus();
  }
  async #commit(){
    if(this.#view.dialog.open)throw new Error(this.#t.propertyPending);
    if(!this.#dirty){if(this.#failure)throw this.#failure;return;}
    if(this.#editor.frozen)throw this.#failure??new Error(this.#t.propertyInvalid);
    const {name,declaration,patch}=this.#view.values();
    const copied={...this.#row.raw,...patch};for(const [key,value]of Object.entries(copied))if(value===undefined)delete copied[key];
    const edit=this.#creating?{type:'create',name,declaration:this.#copy?copied:declaration}:{type:'update',name:this.#name,patch};
    await this.#editor.change(doc=>doc.propertyDefinition(edit));
    this.#name=name;this.#dirty=false;this.#creating=false;this.#clear();this.update(this.#editor.document);this.#onDraft();
  }
  async flush(){await this.#operations;try{await this.#commit();}catch(error){this.#fail(error);throw error;}}
  update(doc){
    if(this.#dirty)return;
    try{this.#rows=createPropertyCatalog(doc.snapshot().project);}catch(error){this.#view.inspection(error);return;}
    document.getElementById('user-property-new').disabled=false;
    this.#row=this.#rows.find(row=>row.name===this.#name)??this.#rows[0];this.#name=this.#row?.name;
    this.#view.showList(this.#rows,this.#name);this.#view.show(this.#row);
  }
  activate(){
    this.#view.panel.hidden=false;
    for(const name of ['property','model','script'])document.getElementById(name+'-panel').hidden=true;
    document.getElementById('binding').hidden=true;document.getElementById('properties-heading').textContent=this.#t.userProperties;
    for(const name of ['properties','model','script','project'])document.getElementById(name+'-workspace').setAttribute('aria-pressed',String(name==='project'));
  }
  deactivate(){this.#view.panel.hidden=true;document.getElementById('project-workspace').setAttribute('aria-pressed','false');}
  setFrozen(value){if(value===this.#locked)return;this.#locked=value;this.#view.enabled(!value);this.#view.panel.inert=value||this.#busy>0;this.#dialogBusy();}
  destroy(){this.#closed=true;this.#view.destroy();}
}
