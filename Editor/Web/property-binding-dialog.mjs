import { inspectPropertyBinding,assertPropertyBindingCapture } from './property-bindings.mjs';
import { PropertyBindingView } from './property-binding-view.mjs';

export class PropertyBindingDialog {
  #editor;#t;#view;#capture;#pending;#failure;#operation=Promise.resolve();#busy=false;#locked=false;#onError;#reset;
  constructor({editor,t,onError,onResetInput}){
    this.#editor=editor;this.#t=t;this.#onError=onError;this.#reset=onResetInput;this.#view=new PropertyBindingView(t);
    this.#view.form.addEventListener('submit',event=>{event.preventDefault();this.#run(()=>this.#commit('bind'));});
    this.#view.remove.addEventListener('click',()=>this.#run(()=>this.#commit('remove')));
    this.#view.cancel.addEventListener('click',()=>{if(!this.#busy&&!this.#locked){this.#close();}});
    this.#view.dialog.addEventListener('cancel',event=>{event.preventDefault();if(!this.#busy&&!this.#locked)this.#close();});
    this.#view.form.addEventListener('input',()=>this.#clearFailure());
    this.#view.form.addEventListener('change',()=>this.#clearFailure());
  }
  get error(){return this.#failure??this.#pending;}
  get hasPendingInput(){return this.#view.dialog.open||this.#busy||Boolean(this.#failure);}
  open(layerId,field){
    if(this.hasPendingInput||this.#locked||this.#editor.frozen)throw new Error(this.#t.bindingPending);
    const selection={layerId,field},state=inspectPropertyBinding(this.#editor.document.snapshot(),selection);
    this.#capture={selection,state,document:this.#editor.document,identity:this.#editor.documentIdentity};
    this.#pending=new Error(this.#t.bindingPending);this.#view.show(state);
  }
  #clearFailure(){const failure=this.#failure;this.#failure=undefined;this.#view.error('');if(failure)this.#reset(failure);}
  #close(){
    const field=this.#capture?.selection.field;this.#view.close();this.#clearFailure();
    if(this.#pending)this.#reset(this.#pending);this.#pending=undefined;this.#capture=undefined;
    if(!this.#locked)document.getElementById('bind-'+field)?.focus();
  }
  #run(operation){
    if(this.#busy||this.#locked||this.#editor.frozen)return;
    // Disable the whole modal synchronously, before entering the async queue.
    this.#busy=true;this.#view.locked(true);
    this.#operation=Promise.resolve().then(operation).catch(error=>{this.#failure=error;this.#view.error(error.message);this.#onError(error);}).finally(()=>{this.#busy=false;this.#view.locked(this.#locked);});
  }
  async #commit(type){
    const capture=this.#capture;
    if(!capture||!this.#view.dialog.open)throw new Error(this.#t.bindingPending);
    const values=type==='bind'?this.#view.values():{};
    assertPropertyBindingCapture(capture,{document:this.#editor.document,identity:this.#editor.documentIdentity,name:values.name,message:this.#t.bindingStale});
    await this.#editor.change(doc=>doc.bindProperty({type,...capture.selection,...values,replace:true}));
    this.#close();
  }
  async flush(){await this.#operation;if(this.error)throw this.error;}
  setFrozen(value){this.#locked=value;this.#view.locked(value||this.#busy);}
  destroy(){this.#view.destroy();}
}
