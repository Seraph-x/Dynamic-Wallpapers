import { SCENE_SCRIPT_PROPERTIES,inspectSceneScript,listSceneScripts } from './script-source.mjs';

export function scriptTargets(scene,layerId) {
  const layer=scene.objects?.find(layer=>layer.id===layerId);
  if(!layer)return [];
  const targets=[...SCENE_SCRIPT_PROPERTIES,...(Object.hasOwn(layer,'text')?['text']:[]),...(Array.isArray(layer.effects)?layer.effects.map((_,index)=>`effects[${index}].visible`):[])];
  const records=targets.map(target=>{const selection={layerId,target},state=inspectSceneScript(scene,selection);return {key:target,label:target,selection,state,source:typeof state.source==='string'?state.source:Object.hasOwn(state,'source')?JSON.stringify(state.source,null,2):''};});
  for(const record of listSceneScripts(scene).filter(record=>record.layerId===layerId&&!record.registered)) {
    records.push({key:'metadata:'+JSON.stringify(record.path),label:record.path.join('.'),state:{editable:false,kind:'unsupported',reason:record.reason},source:typeof record.source==='string'?record.source:JSON.stringify(record.source,null,2)});
  }
  return records;
}

// Textarea exposes LF text. Keep a consistently CRLF source's original style;
// mixed imported endings are untouched until input, then use the displayed LF.
export function scriptInputSource(value,original) {
  return original.includes('\r\n')&&!/(?<!\r)\n/.test(original)?value.replace(/\r?\n/g,'\r\n'):value;
}
