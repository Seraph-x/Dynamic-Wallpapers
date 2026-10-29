import { scriptLineSelection } from './script-navigation.mjs';
import { ScriptDraft } from './script-draft.mjs';
import { ResourceScriptDraft } from './resource-script-draft.mjs';
import {discoverEditorResourceScripts} from './resource-api.mjs';
import { initializeScriptView } from './script-workspace-view.mjs';
import { scriptTargets,resourceScriptTargets,resourceTargetKey,scriptInputSource } from './script-workspace-targets.mjs';

export class ScriptWorkspace {
  #editor;#t;#onError;#reset;#onDraft;#view;#records=[];#draft;#record;#id;#document;
  #locked=false;#busy=0;#closed=false;#operations=Promise.resolve();#failure;#diagnostics=[];#diagnosticSource;
  #loading;#loadSequence=0;
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
      void this.#run(async()=>{await this.#commit();await this.#load(editor.document,this.#id,key);});
    });
    const bind=(name,operation)=>document.getElementById('script-'+name).addEventListener('click',()=>{void this.#run(operation);});
    bind('check',()=>{this.#clearFailure();this.#draft.check();this.#checked();this.#render();});
    bind('apply',()=>this.#commit(true));
    bind('remove',async()=>{this.#clearFailure();this.#diagnostics=[];this.#diagnosticSource=undefined;if(this.#record?.resource)await this.#draft.remove();else await editor.change(doc=>this.#draft.remove(doc));this.#onDraft();});
    bind('revert',async()=>{this.#clearFailure();this.#diagnostics=[];this.#diagnosticSource=undefined;await this.#draft?.revert(editor.document);await this.#load(editor.document,this.#id,this.#record?.key);this.#onDraft();});
  }
  get hasPendingInput(){return this.dirty||Boolean(this.#failure)||this.#locked||this.#busy>0||Boolean(this.#loading)||this.#view.pending;}
  async reveal(link){await this.#loading;if(this.hasPendingInput)throw new Error(this.#t.navPending);await this.#load(this.#editor.document,link.layerId,link.resource?resourceTargetKey({path:link.resource.path,anchor:link.resource.pointer.slice(0,-1)}):link.target);this.activate();this.#view.reveal(scriptLineSelection(link.source,link.line));}
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
    if(this.#record?.resource){await this.#draft.apply();this.#checked();}
    else await this.#editor.change(doc=>{this.#draft.check();this.#draft.apply(doc);this.#checked();});
    this.#onDraft();
  }
  #load(document,id,key) {
    const sequence=++this.#loadSequence;
    const records=scriptTargets(document.snapshot().scene,id);
    const loading=(async()=>{
      const report=await discoverEditorResourceScripts(this.#editor);
      if(sequence!==this.#loadSequence||this.#closed)return;
      records.push(...resourceScriptTargets(report));
      const record=records.find(record=>record.key===key)??records.find(record=>record.state.kind==='script')??records.find(record=>record.state.editable)??records[0];
      const draft=record?.resource&&record.state.editable?await ResourceScriptDraft.open(this.#editor,record.resource):record?.selection?new ScriptDraft(document,record.selection):undefined;
      if(sequence!==this.#loadSequence||this.#closed)return;
      const sameContext=this.#document===document&&this.#id===id&&this.#record?.key===record?.key;
      if(!sameContext||record?.source!==this.#diagnosticSource){this.#diagnostics=[];this.#diagnosticSource=undefined;}
      this.#document=document;this.#id=id;this.#records=records;
      this.#record=record;this.#draft=draft;
      this.#view.targets(this.#records,this.#record?.key);
    })().catch(error=>{
      // A newer document update owns discovery now. Its result/error must be
      // observed instead of letting the retired scan reject a pending flush.
      if(sequence===this.#loadSequence&&!this.#closed)throw error;
    });
    const settled=loading.finally(()=>{if(sequence===this.#loadSequence){this.#loading=undefined;this.#render();}});
    this.#loading=settled;this.#render();
    return settled;
  }
  update(document,id) {
    if(this.dirty||this.#busy){this.#render();return;}
    const sequence=this.#loadSequence+1;
    void this.#load(document,id,this.#id===id?this.#record?.key:undefined).catch(error=>{if(sequence===this.#loadSequence&&!this.#closed)this.#fail(error);});
  }
  #render() {
    const state=this.#draft?.state??this.#record?.state;
    const issues=this.#diagnostics;
    this.#view.render({source:this.#draft?.state.editable?this.#draft.source:this.#record?.source,state,dirty:this.dirty,locked:this.#locked||this.#busy>0||Boolean(this.#loading),
      failure:this.#failure,diagnostics:issues.length?issues:[],context:this.#document,key:JSON.stringify([this.#id,this.#record?.key]),target:this.#record?.target??this.#record?.selection?.target,resource:this.#record?.resource,consumers:this.#record?.consumers});
  }
  activate() {
    document.body.classList.add('script-workspace-active');this.#view.panel.hidden=false;
    document.getElementById('model-panel').hidden=true;document.getElementById('property-panel').hidden=true;document.getElementById('binding').hidden=true;
    document.getElementById('properties-heading').textContent=this.#t.scriptWorkspace;
    for(const name of ['properties','model','script'])document.getElementById(name+'-workspace').setAttribute('aria-pressed',String(name==='script'));
  }
  deactivate(){this.#view.panel.hidden=true;document.body.classList.remove('script-workspace-active');document.getElementById('script-workspace').setAttribute('aria-pressed','false');}
  cancelDiscovery(){this.#loadSequence++;this.#loading=undefined;this.#render();}
  setFrozen(value){this.#locked=value;this.#render();}
  async flush() {
    await this.#operations;
    while(this.#loading){
      const sequence=this.#loadSequence,pending=this.#loading;
      try{await pending;}catch(error){if(sequence===this.#loadSequence)throw error;}
    }
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
  destroy(){this.#closed=true;this.#loadSequence++;this.#view.destroy();}
}
