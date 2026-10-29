import {discoverEditorResourceScripts,captureResourceScript,prepareResourceScript,commitResourceScript} from './resource-api.mjs';

/** An asynchronous resource adapter with the same local-input contract as ScriptDraft. */
export class ResourceScriptDraft {
 #editor;#record;#capture;#source;#input=false;#proposal;#diagnostics=[];#busy=false;
 static async open(editor,record){
  const draft=new ResourceScriptDraft();draft.#editor=editor;
  await draft.#adopt(record);return draft;
 }
 get state(){return {editable:true,kind:this.#capture.hasScript?'script':'constant',source:this.#capture.hasScript?this.#capture.source:undefined,valueKind:this.#capture.valueKind};}
 get source(){return this.#source;}
 get dirty(){return this.#source!==this.#capture.source||this.#input&&!this.#capture.hasScript;}
 get diagnostics(){return structuredClone(this.#diagnostics);}
 #assertIdle(){if(this.#busy)throw new Error('Resource script draft operation is pending');}
 setSource(source){
  this.#assertIdle();
  if(typeof source!=='string'||source.includes('\0')||/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(source))throw new TypeError('Script source must contain valid Unicode without NUL');
  this.#source=source;this.#input=true;this.#proposal=undefined;this.#diagnostics=[];
 }
 restoreInput(){this.#assertIdle();this.#source=this.#capture.source;this.#input=false;this.#proposal=undefined;this.#diagnostics=[];}
 check(){
  this.#assertIdle();
  try{
   // Preparation validates the captured owner/revision on every Check.
   this.#proposal=prepareResourceScript(this.#capture,{type:'set',source:this.#source});
   this.#diagnostics=this.#proposal.diagnostics;return structuredClone(this.#proposal.check);
  }catch(error){
   if(error.name==='ResourceScriptSyntaxError')this.#diagnostics=[{level:'error',code:'SYNTAX',message:error.message,line:error.line}];
   throw error;
  }
 }
 async #adopt(record){
  const capture=await captureResourceScript(this.#editor,record);
  this.#record=record;this.#capture=capture;this.#source=capture.source;this.#input=false;this.#proposal=undefined;this.#diagnostics=[];
 }
 async #currentRecord(){
  const report=await discoverEditorResourceScripts(this.#editor);
  const record=report.records.find(value=>value.path===this.#record.path&&JSON.stringify(value.anchor)===JSON.stringify(this.#record.anchor));
  if(!record)throw new Error('Resource script source is no longer available');
  return record;
 }
 async #commit(proposal){
  this.#busy=true;
  try{
   const result=await commitResourceScript(this.#editor,proposal);
   await this.#adopt(await this.#currentRecord());this.#diagnostics=result.diagnostics;
   return result.changed;
  }finally{this.#busy=false;}
 }
 async apply(){
  this.#assertIdle();if(!this.dirty)return false;
  this.check();return this.#commit(this.#proposal);
 }
 async remove(){
  this.#assertIdle();
  if(!this.#capture.hasScript){this.restoreInput();return false;}
  return this.#commit(prepareResourceScript(this.#capture,{type:'remove'}));
 }
 async revert(){
  this.#assertIdle();this.#busy=true;
  try{await this.#adopt(await this.#currentRecord());}finally{this.#busy=false;}
 }
}
