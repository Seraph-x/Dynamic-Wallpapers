import { ScriptDraft } from './script-draft.mjs';
import { initializeScriptView } from './script-workspace-view.mjs';
import { scriptTargets,scriptInputSource } from './script-workspace-targets.mjs';

export class ScriptWorkspace {
  #editor;#t;#onError;#reset;#onDraft;#view;#records=[];#draft;#record;#id;#document;
  #locked=false;#busy=0;#closed=false;#operations=Promise.resolve();#failure;#diagnostics=[];#diagnosticSource;
  constructor({editor,t,onError,onResetInput,onDraftChange}) {
    this.#editor=editor;this.#t=t;this.#onError=onError;this.#reset=onResetInput;this.#onDraft=onDraftChange;
    this.#view=initializeScriptView(t,{onError:error=>this.#fail(error),onResolved:expected=>{if(this.#failure===expected){this.#clearFailure();this.#render();}}});
    this.#view.onInput(value=>{
      try {
        if(this.#locked||this.#busy||editor.frozen)throw new Error('Editor is frozen');
        if(this.#draft.state.kind==='constant'&&value==='')this.#draft.restoreInput();
        else this.#draft.setSource(scriptInputSource(value,this.#draft.state.source??''));
        this.#clearFailure();this.#diagnostics=[];this.#diagnosticSource=undefined;this.#render();this.#onDraft();
      } catch(error){this.#fail(error);}
    });
    this.#view.target.addEventListener('change',()=>{
      const key=this.#view.target.value;this.#view.target.value=this.#record?.key??'';
      void this.#run(async()=>{await this.#commit();this.#load(editor.document,this.#id,key);});
    });
    const bind=(name,operation)=>document.getElementById('script-'+name).addEventListener('click',()=>{void this.#run(operation);});
    bind('check',()=>{this.#clearFailure();this.#draft.check();this.#checked();this.#render();});
    bind('apply',()=>this.#commit(true));
    bind('remove',async()=>{this.#clearFailure();this.#diagnostics=[];this.#diagnosticSource=undefined;await editor.change(doc=>this.#draft.remove(doc));this.#onDraft();});
    bind('revert',()=>{this.#clearFailure();this.#diagnostics=[];this.#diagnosticSource=undefined;this.#draft?.revert(editor.document);this.#load(editor.document,this.#id,this.#record?.key);this.#onDraft();});
  }
  get dirty(){return this.#draft?.dirty??false;}
  get error(){return this.#failure;}
  #clearFailure(){const previous=this.#failure;this.#failure=undefined;if(previous)this.#reset(previous);}
  #fail(error){this.#failure=error;this.#render();this.#onError(error);}
  #run(operation) {
    const accepted=!this.#locked&&!this.#editor.frozen&&!this.#closed;
    this.#busy++;this.#render();
    const result=this.#operations.then(async()=>{if(!accepted)throw new Error('Editor is closed or frozen');return operation();});
    // Preserve the actual rejection for diagnostics; recovery keeps the next
    // explicit edit/Revert usable instead of poisoning the operation queue.
    this.#operations=result.catch(()=>{});
    void result.catch(error=>this.#fail(error)).finally(()=>{this.#busy--;this.#render();});
    return result;
  }
  #checked(){this.#diagnosticSource=this.#draft.source;const issues=this.#draft.diagnostics;this.#diagnostics=issues.length?issues:[{level:'info',message:this.#t.scriptCheckPassed}];}
  async #commit(force=false) {
    if(!this.#draft||(!force&&!this.dirty))return;
    this.#clearFailure();
    if(force&&!this.dirty&&this.#draft.state.kind==='constant')this.#draft.setSource(this.#draft.source);
    await this.#editor.change(doc=>{this.#draft.check();this.#draft.apply(doc);this.#checked();});
    this.#onDraft();
  }
  #load(document,id,key) {
    const sameContext=this.#document===document&&this.#id===id&&this.#record?.key===key;
    this.#document=document;this.#id=id;this.#records=scriptTargets(document.snapshot().scene,id);
    this.#record=this.#records.find(record=>record.key===key)??this.#records.find(record=>record.state.kind==='script')??this.#records.find(record=>record.state.editable)??this.#records[0];
    if(!sameContext||this.#record?.source!==this.#diagnosticSource){this.#diagnostics=[];this.#diagnosticSource=undefined;}
    this.#draft=this.#record?.selection?new ScriptDraft(document,this.#record.selection):undefined;
    this.#view.targets(this.#records,this.#record?.key);this.#render();
  }
  update(document,id) {
    if(this.dirty){this.#render();return;}
    this.#load(document,id,this.#id===id?this.#record?.key:undefined);
  }
  #render() {
    const state=this.#draft?.state??this.#record?.state;
    const issues=this.#diagnostics;
    this.#view.render({source:this.#draft?.state.editable?this.#draft.source:this.#record?.source,state,dirty:this.dirty,locked:this.#locked||this.#busy>0,
      failure:this.#failure,diagnostics:issues.length?issues:[],context:this.#document,key:JSON.stringify([this.#id,this.#record?.key]),target:this.#record?.selection?.target});
  }
  activate() {
    document.body.classList.add('script-workspace-active');this.#view.panel.hidden=false;
    document.getElementById('model-panel').hidden=true;document.getElementById('property-panel').hidden=true;document.getElementById('binding').hidden=true;
    document.getElementById('properties-heading').textContent=this.#t.scriptWorkspace;
    for(const name of ['properties','model','script'])document.getElementById(name+'-workspace').setAttribute('aria-pressed',String(name==='script'));
  }
  deactivate(){this.#view.panel.hidden=true;document.body.classList.remove('script-workspace-active');document.getElementById('script-workspace').setAttribute('aria-pressed','false');}
  setFrozen(value){this.#locked=value;this.#render();}
  async flush() {
    await this.#operations;
    try { this.#view.assertSettled(); } catch(error){this.#fail(error);throw error;}
    // A prior freeze already attempted the draft. Preserve that exact rejection
    // for the owner's validation snapshot; never retry a write while frozen.
    if(this.#editor.frozen){if(this.#failure)throw this.#failure;if(this.dirty)throw new Error('Source draft remains pending in a frozen Editor');return;}
    try {
      // Single direction: Timeline may prepare source, source never waits for
      // Timeline. In particular native freeze must not wait on its own action.
      await this.#commit();
      if(this.#failure)throw this.#failure;
    } catch(error){this.#fail(error);throw error;}
  }
  destroy(){this.#closed=true;this.#view.destroy();}
}
