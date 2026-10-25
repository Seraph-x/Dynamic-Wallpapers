import { checkSceneScript } from '@webwallgl/editor';
import { editSceneScript,listSceneScripts } from './script-source.mjs';
export {checkSceneScript};
export {SCENE_SCRIPT_PROPERTIES,inspectSceneScript,editSceneScript,listSceneScripts} from './script-source.mjs';
const proposals=new WeakMap();
function freeze(value){if(value&&typeof value==='object'){Object.values(value).forEach(freeze);Object.freeze(value);}return value;}
function equivalent(left,right){
 const pending=[[left,right]];
 while(pending.length){const [a,b]=pending.pop();if(Object.is(a,b))continue;if(!a||!b||typeof a!=='object'||typeof b!=='object'||Array.isArray(a)!==Array.isArray(b))return false;
  if(Array.isArray(a)&&a.length!==b.length)return false;
  const keys=Object.keys(a);if(keys.length!==Object.keys(b).length||keys.some(key=>!Object.hasOwn(b,key)))return false;for(const key of keys)pending.push([a[key],b[key]]);
 }
 return true;
}
function checkedDiagnostics(check){
 if(!check.ok)return [{level:'error',code:'SYNTAX',message:check.message,line:check.line}];
 return check.noEntry?[{level:'warning',code:'NO_ENTRY',message:'The native checker found no recognized entry or engine clock use; the runtime can discard this source.',line:null}]:[];
}
/** Syntax checking constructs functions but never invokes supplied source. */
export function prepareSceneScript(document,request){
 if(!document||typeof document.snapshot!=='function'||typeof document.script!=='function')throw new Error('Expected a SceneDocument');
 const edit=structuredClone(request),snapshot=document.snapshot();editSceneScript(snapshot.scene,edit);
 const check=edit.type==='set'?checkSceneScript(edit.source):null;
 if(check&&!check.ok)throw Object.assign(new Error(check.message),{name:'SceneScriptSyntaxError',layerId:edit.layerId,target:edit.target,line:check.line,check:freeze(structuredClone(check))});
 const proposal=freeze({layerId:edit.layerId,target:edit.target,type:edit.type,check:check?structuredClone(check):null,diagnostics:check?checkedDiagnostics(check):[]});
 proposals.set(proposal,{document,snapshot:structuredClone(snapshot),edit});return proposal;
}
export function applySceneScript(document,proposal){
 const captured=proposals.get(proposal);if(!captured)throw new Error('Script edit proposal is forged or already consumed');
 if(captured.document!==document||!equivalent(captured.snapshot,document.snapshot()))throw new Error('Script edit document changed; the proposal is stale');
 document.script(captured.edit);proposals.delete(proposal);
}
/** Unregistered script-like metadata is retained, explicitly unvalidated. */
export function checkSceneScriptSources(scene){
 const results=listSceneScripts(scene).map(record=>{
  if(!record.registered)return {...record,checked:false,check:null,diagnostics:[{level:'info',code:'UNREGISTERED_ANCHOR',message:record.reason??'Unregistered script-like metadata is read-only and was not checked.',line:null}]};
  const check=checkSceneScript(record.source);return {...record,checked:true,check,diagnostics:checkedDiagnostics(check)};
 });
 const diagnostics=results.flatMap(result=>result.diagnostics),errors=diagnostics.filter(d=>d.level==='error').length;
 return {scope:'inline-native-scene-scripts',discovered:results.length,checked:results.filter(r=>r.checked).length,unvalidated:results.filter(r=>!r.checked).length,errors,warnings:diagnostics.filter(d=>d.level==='warning').length,ok:errors===0,results};
}
