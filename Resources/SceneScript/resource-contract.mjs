import { parseResourceJSON, jsonNodeAt, jsonMembers, assertSourceString, setJSONStringMember, removeJSONMember, replaceJSONValue } from './json-spans.mjs';

const numericOverrides = new Set(['rate','count','size','speed','lifetime','brightness','alpha']);
const genericTintKinds = new Map([['color','vector3'],['alpha','scalar'],['brightness','scalar']]);
const particleConstants = new Set(['ui_editor_properties_refract_amount','ui_editor_properties_overbright']);
const samePath = (left,right) => left.length === right.length && left.every((part,index)=>part===right[index]);

export function resourceScriptPath(path) {
  assertSourceString(path);
  if (!path || /[\\:]/.test(path) || path.split('/').some(part=>!part || part==='.' || part==='..')) throw new Error('Invalid resource script path');
  return path;
}

function primitiveKind(node, particle=false) {
  if (node?.kind === 'number' && Number.isFinite(node.value)) return 'scalar';
  const values = node?.kind === 'string' ? node.value.trim().split(particle ? /\s+/ : /[\s,]+/).map(Number) :
    node?.kind === 'array' ? node.items.map(item=>item.kind==='number' ? item.value : NaN) : null;
  if (values && [2,3,4].includes(values.length) && values.every(Number.isFinite)) return `vector${values.length}`;
  return undefined;
}

function customUniformPath(shader) {
  const name=shader.toLowerCase();
  return name==='generic'||!(name.startsWith('generic')||['foliage4','puppettexturechannels','sprite','flat'].includes(name));
}

function tintKind(document,key) {
  const shader=jsonNodeAt(document,['passes',0,'shader'])?.value;
  if(shader==='generic4')return genericTintKinds.get(key.toLowerCase());
  const combos=jsonNodeAt(document,['passes',0,'combos']);
  const versions=combos?.kind==='object'?combos.members.filter(member=>member.key.toLowerCase()==='version'):[];
  if(versions.length>1)throw new Error('Ambiguous material shader version');
  const version=versions[0]?.value.value;
  if((version===undefined||version<2)&&/^generic(image)?[123]?$/i.test(shader))return ['alpha','brightness'].includes(key.toLowerCase())?'scalar':undefined;
}

function materialKind(document,key,consumers) {
  const shader=jsonNodeAt(document,['passes',0,'shader'])?.value;
  if(typeof shader!=='string')return 'material';
  const active=consumers.filter(consumer=>consumer.consumed!==false);
  if(active.some(consumer=>consumer.kind==='tint'||consumer.kind==='mesh'&&!customUniformPath(shader))){const kind=tintKind(document,key);if(kind)return kind;}
  if(active.some(consumer=>consumer.kind==='particle'&&!customUniformPath(shader))&&particleConstants.has(key))return 'scalar';
  return 'material';
}

function materialReason(document, key, consumers) {
  const shader = jsonNodeAt(document,['passes',0,'shader'])?.value;
  if (!consumers.length) return 'Resource has no consuming layer reference';
  if (typeof shader !== 'string' || !shader) return 'Material has no consumed shader';
  for (const consumer of consumers) {
    if (consumer.consumed === false) continue;
    if (consumer.kind==='effect'||['mesh','particle'].includes(consumer.kind)&&customUniformPath(shader)) return undefined;
    if(consumer.kind==='particle'&&particleConstants.has(key))return undefined;
    if(['mesh','tint'].includes(consumer.kind)&&tintKind(document,key))return undefined;
  }
  return consumers.find(consumer=>consumer.unavailableReason)?.unavailableReason ?? 'This material consumer does not consume the selected constant';
}

function scriptState(document, anchor, expectedKind, reason) {
  const node = jsonNodeAt(document,anchor), wrapper = node?.kind === 'object';
  const sourceNode = wrapper ? jsonNodeAt(document,[...anchor,'script']) : undefined;
  const base = wrapper ? jsonNodeAt(document,[...anchor,'value']) : node;
  const valueKind = primitiveKind(base,expectedKind==='particle-color');
  if (wrapper && (jsonNodeAt(document,[...anchor,'user']) || jsonNodeAt(document,[...anchor,'animation']))) reason ??= 'An existing user or animation binding controls this field';
  if (!valueKind || expectedKind==='scalar' && valueKind!=='scalar' || expectedKind==='particle-color' && valueKind!=='vector3' || expectedKind.startsWith('vector') && valueKind!==expectedKind) reason ??= `Unsupported or missing ${expectedKind} resource script base value`;
  if (sourceNode) {
    try { assertSourceString(sourceNode.value); }
    catch (error) { reason ??= error.message; }
  }
  return {editable:!reason, ...(reason ? {reason} : {}), valueKind,
    hasScript:Boolean(sourceNode), ...(sourceNode?.kind==='string' ? {source:sourceNode.value} : {}),
    ...(sourceNode ? {rawSource:document.text.slice(sourceNode.start,sourceNode.end)} : {})};
}

function candidates(document, kind) {
  const anchors = [], errors = [];
  function members(path, expectedKind) {
    try {
      const node = jsonNodeAt(document,path);
      if (node?.kind === 'object') for (const member of node.members) anchors.push({anchor:[...path,member.key],expectedKind});
    } catch (error) { errors.push(error.message); }
  }
  if (kind === 'material') members(['passes',0,'constantshadervalues'],'material');
  if (kind === 'particle') {
    for (const field of ['emitter','children']) {
      let items;
      try { items = jsonNodeAt(document,[field]); } catch (error) { errors.push(error.message); continue; }
      if (items?.kind !== 'array') continue;
      for (let index=0; index<items.items.length; index++) {
        if (field === 'emitter') {
          try { if (jsonNodeAt(document,[field,index,'rate'])) anchors.push({anchor:[field,index,'rate'],expectedKind:'scalar'}); }
          catch (error) { errors.push(error.message); }
        } else {
          const before = anchors.length;
          members([field,index,'instanceoverride'],'particle-override');
          for (let cursor=anchors.length-1; cursor>=before; cursor--) {
            const entry=anchors[cursor],key=entry.anchor.at(-1);
            if (key==='colorn') entry.expectedKind='particle-color';
            else if (numericOverrides.has(key)) entry.expectedKind='scalar';
            else anchors.splice(cursor,1);
          }
        }
      }
    }
  }
  return {anchors,errors};
}

/** Data-only schema registration. Registration and syntax checking do not claim playback. */
export function inspectResourceScripts({path,bytes,kind='unknown',consumers=[]}) {
  resourceScriptPath(path);
  if (!['material','particle','unknown'].includes(kind)) throw new Error('Unknown resource script document kind');
  if (!Array.isArray(consumers) || consumers.some(consumer=>!consumer || typeof consumer.kind!=='string')) throw new TypeError('Invalid resource script consumers');
  const ownedConsumers = structuredClone(consumers);
  const document = parseResourceJSON(bytes,{mode:kind==='particle' ? 'json' : 'jsonc'});
  const {anchors,errors} = candidates(document,kind), records = [], selected = new Set();
  for (const {anchor,expectedKind} of anchors) {
    const key=JSON.stringify(anchor);
    if (selected.has(key)) continue;
    selected.add(key);
    let state;
    try {
      let reason;
      if (kind==='material') reason=materialReason(document,anchor.at(-1),ownedConsumers);
      else if (!ownedConsumers.some(consumer=>consumer.kind==='particle')) reason='Resource has no consuming particle reference';
      if (kind==='particle' && anchor[0]==='children' && typeof jsonNodeAt(document,['children',anchor[1],'name'])?.value!=='string') reason ??= 'Particle child has no resource reference';
      state=scriptState(document,anchor,kind==='material'?materialKind(document,anchor.at(-1),ownedConsumers):expectedKind,reason);
    } catch (error) { state={editable:false,reason:error.message,hasScript:false}; }
    records.push({path,kind,anchor,scriptPath:[...anchor,'script'],registered:true,consumers:structuredClone(ownedConsumers),...state});
  }
  for (const found of jsonMembers(document,'script')) {
    const anchor=found.path.slice(0,-1), existing=records.find(record=>samePath(record.anchor,anchor));
    if (existing && !found.ambiguous && existing.hasScript) continue;
    const reason=found.ambiguous ? 'Ambiguous duplicate resource script path' : existing?.reason ?? 'Unregistered resource script-like metadata';
    if (existing) { existing.editable=false; existing.reason=reason; }
    if (!existing || found.ambiguous) records.push({path,kind,anchor,scriptPath:found.path,registered:false,editable:false,reason,hasScript:true,occurrence:found.node.start,
      ...(found.node.kind==='string' ? {source:found.node.value} : {}),rawSource:document.text.slice(found.node.start,found.node.end),consumers:structuredClone(ownedConsumers)});
  }
  return {records,errors};
}

/** Patch only authored source/member spans; the caller owns syntax checking and staging. */
export function patchResourceScript(input) {
  if (!['set','remove'].includes(input.type)) throw new Error('Invalid resource script edit');
  if (!Array.isArray(input.anchor)) throw new Error('Invalid resource script anchor');
  if (input.type==='set') assertSourceString(input.source);
  const {records}=inspectResourceScripts(input),record=records.find(record=>samePath(record.anchor,input.anchor));
  if (!record) throw new Error('Unknown resource script anchor');
  if (!record.registered || !record.editable) throw new Error(record.reason);
  const document=parseResourceJSON(input.bytes,{mode:input.kind==='particle' ? 'json' : 'jsonc'});
  const node=jsonNodeAt(document,input.anchor);
  if (input.type==='remove') return node.kind==='object' ? removeJSONMember(document,input.anchor,'script') : document.bytes();
  if (node.kind==='object') return setJSONStringMember(document,input.anchor,'script',input.source);
  const literal=document.text.slice(node.start,node.end);
  return replaceJSONValue(document,input.anchor,'{"value":'+literal+',"script":'+JSON.stringify(input.source)+'}');
}
