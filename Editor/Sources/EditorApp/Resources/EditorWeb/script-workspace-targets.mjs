import { SCENE_SCRIPT_PROPERTIES,PARTICLE_SCRIPT_PROPERTIES,inspectSceneScript,listSceneScripts } from './script-source.mjs';

export const resourceTargetKey=record=>'resource:'+JSON.stringify([record.path,record.anchor]);
export function resourceScriptTargets(report){
  return report.records.map(record=>({key:resourceTargetKey(record),label:`${record.path} · ${JSON.stringify(record.anchor)}`,
    resource:record,consumers:record.consumers??[],target:'resource:'+record.valueKind,
    state:{editable:record.editable,kind:record.editable?(record.hasScript?'script':'constant'):'unsupported',source:record.source,reason:record.reason,valueKind:record.valueKind},
    source:typeof record.source==='string'?record.source:record.hasScript?JSON.stringify(record.source,null,2):''}));
}
export function resourceConsumerLabels(consumers,scene){
  const slots={pass:'passes',child:'children',mesh:'meshes',skin:'materials'};
  return consumers.map(consumer=>{
    const layer=scene.objects?.[consumer.layerIndex];
    const root=Object.hasOwn(consumer,'effect')?`.effects[${consumer.effect}]`:layer?.particle?'.particle':layer?.model?'.model':'.image';
    const references=(consumer.via??[]).map(edge=>edge.path+Object.entries(slots).filter(([key])=>Object.hasOwn(edge,key)).map(([key,name])=>` · ${name}[${edge[key]}]`).join(''));
    return {name:layer?.name||String(consumer.layerId??consumer.layerIndex),location:[`objects[${consumer.layerIndex}]${root}`,...references].join(' → ')};
  });
}

export function scriptTargets(scene,layerId) {
  const layer=scene.objects?.find(layer=>layer.id===layerId);
  if(!layer)return [];
  const targets=[...SCENE_SCRIPT_PROPERTIES,...(Object.hasOwn(layer,'text')?['text']:[]),...(Array.isArray(layer.effects)?layer.effects.map((_,index)=>`effects[${index}].visible`):[]),...PARTICLE_SCRIPT_PROPERTIES.filter(key=>layer.instanceoverride&&Object.hasOwn(layer.instanceoverride,key)).map(key=>'instanceoverride.'+key)];
  const records=targets.map(target=>{const selection={layerId,target},state=inspectSceneScript(scene,selection);return {key:target,label:target,selection,state,...(target.startsWith('instanceoverride.')?{target:'resource:'+(target.endsWith('.colorn')?'vector3':'scalar')} :{}),source:typeof state.source==='string'?state.source:Object.hasOwn(state,'source')?JSON.stringify(state.source,null,2):''};});
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
