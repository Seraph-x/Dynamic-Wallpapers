const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const own = (value, key) => Object.hasOwn(value, key);
const vectors = new Set(['origin','scale','angles','color']);
const scalars = new Set(['alpha','brightness','maxwidth','pointsize','volume','intensity','exponent']);
const defaults = Object.freeze({origin:'0 0 0',angles:'0 0 0',scale:'1 1 1',color:'1 1 1',alpha:1,visible:true});
export const SCENE_SCRIPT_PROPERTIES = Object.freeze([...vectors,...scalars,'visible']);
export const PARTICLE_SCRIPT_PROPERTIES=Object.freeze(['rate','count','size','speed','lifetime','brightness','alpha','colorn']);

// Iterative copies and ancestor tracking handle deeply nested imported JSON and
// expose cycles explicitly, while retaining shared, non-cyclic object references.
function copyTree(value) {
  if (value === null || typeof value !== 'object') return value;
  const make = item => Array.isArray(item) ? new Array(item.length) : {};
  const result = make(value), copies = new WeakMap([[value,result]]), active = new WeakSet([value]);
  const stack = [{input:value,output:result,keys:Object.keys(value),index:0}];
  while (stack.length) {
    const frame = stack.at(-1);
    if (frame.index === frame.keys.length) { active.delete(frame.input); stack.pop(); continue; }
    const key = frame.keys[frame.index++], child = frame.input[key];
    let copied = child;
    if (child !== null && typeof child === 'object') {
      if (active.has(child)) throw new Error('Cyclic scene data');
      copied = copies.get(child);
      if (!copied) {
        copied = make(child); copies.set(child,copied); active.add(child);
        stack.push({input:child,output:copied,keys:Object.keys(child),index:0});
      }
    }
    Object.defineProperty(frame.output,key,{value:copied,writable:true,enumerable:true,configurable:true});
  }
  return result;
}

function validSource(source) {
  if (typeof source !== 'string') throw new Error('Script source must be a string');
  if (source.includes('\0')) throw new Error('Script source cannot contain NUL');
  for (let index = 0; index < source.length; index++) {
    const code = source.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = source.charCodeAt(++index);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new Error('Script source must contain valid Unicode');
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error('Script source must contain valid Unicode');
  }
}

function anchor(scene, selection) {
  if (!object(scene) || (scene.objects !== undefined && !Array.isArray(scene.objects))) throw new Error('Invalid scene objects');
  if (!object(selection) || selection.layerId === undefined || selection.layerId === null) throw new Error('A layer ID is required');
  const matches = (scene.objects ?? []).filter(layer => object(layer) && own(layer,'id') && layer.id === selection.layerId);
  if (matches.length !== 1) throw new Error(matches.length ? 'Ambiguous duplicate layer ID' : 'Layer does not exist');
  const layer = matches[0], target = selection.target, path = ['objects',scene.objects.indexOf(layer)];
  if (SCENE_SCRIPT_PROPERTIES.includes(target) || (target === 'text' && own(layer,'text'))) return {container:layer,key:target,property:target,path:[...path,target]};
  const particle=typeof target==='string'&&target.startsWith('instanceoverride.')?target.slice(17):null;
  if(particle&&PARTICLE_SCRIPT_PROPERTIES.includes(particle)){
    if(typeof layer.particle!=='string'||!layer.particle||!object(layer.instanceoverride)||!own(layer.instanceoverride,particle))throw new Error('Particle override has no owned base or consuming particle reference');
    return {container:layer.instanceoverride,key:particle,property:particle==='colorn'?'particle-color':'particle-scalar',path:[...path,'instanceoverride',particle]};
  }
  const effect = typeof target === 'string' ? /^effects\[(0|[1-9]\d*)\]\.visible$/.exec(target) : null;
  if (effect) {
    const index = Number(effect[1]);
    if (!Number.isSafeInteger(index) || !Array.isArray(layer.effects) || !object(layer.effects[index])) throw new Error('Effect does not exist');
    return {container:layer.effects[index],key:'visible',property:'visible',path:[...path,'effects',index,'visible']};
  }
  throw new Error('Unsupported script target');
}

function validBase(value, property) {
  if (vectors.has(property)||property==='particle-color') {
    const components = typeof value === 'string' && value.trim() ? value.trim().split(/\s+/).map(Number) : value;
    return Array.isArray(components) && components.length === 3 && [0,1,2].every(index => Number.isFinite(components[index]));
  }
  if (scalars.has(property)||property==='particle-scalar') return typeof value === 'number' && Number.isFinite(value);
  return typeof value === (property === 'visible' ? 'boolean' : 'string');
}

function stateOf({container,key,property}) {
  const raw = own(container,key) ? container[key] : defaults[property];
  const wrapper = object(raw), hasSource = wrapper && own(raw,'script');
  const value = wrapper ? raw.value : raw;
  const state = {kind:hasSource ? 'script' : 'constant',...(hasSource ? {source:raw.script} : {}),value,editable:true};
  if (wrapper && (own(raw,'user') || own(raw,'animation'))) {
    return {...state,kind:'bound',editable:false,reason:'An existing user or animation binding controls this field'};
  }
  try {
    if (hasSource) validSource(raw.script);
    if ((!wrapper || own(raw,'value')||property.startsWith('particle-')) && !validBase(value,property)) throw new Error('Unsupported script base value');
    if (wrapper && !own(raw,'value') && !hasSource) throw new Error('Unsupported property wrapper without a base value');
  } catch (error) { return {...state,kind:'unsupported',editable:false,reason:error.message}; }
  return state;
}

export function inspectSceneScript(scene, selection) {
  const owned = copyTree(scene);
  try { return stateOf(anchor(owned,selection)); }
  catch (error) { return {kind:'unsupported',editable:false,reason:error.message}; }
}

export function editSceneScript(scene, edit) {
  if (!object(edit) || !['set','remove'].includes(edit.type)) throw new Error('Invalid script edit');
  if (edit.type === 'set') validSource(edit.source);
  const owned = copyTree(scene), selected = anchor(owned,edit), state = stateOf(selected);
  if (!state.editable) throw new Error(state.reason);
  // Detach only the selected structural path. Imported API callers may share
  // arrays, effects or wrappers elsewhere; those aliases must stay unchanged.
  let container = owned;
  for (const key of selected.path.slice(0,-1)) {
    container[key] = Array.isArray(container[key]) ? container[key].slice() : {...container[key]};
    container = container[key];
  }
  const {key} = selected;
  if (edit.type === 'remove') {
    if (object(container[key])) { container[key] = {...container[key]}; delete container[key].script; }
  } else if (object(container[key])) container[key] = {...container[key],script:edit.source};
  else container[key] = {value:state.value,script:edit.source};
  return owned;
}

function structuralPath(link) {
  const path = [];
  for (let cursor = link; cursor; cursor = cursor.parent) path.push(cursor.key);
  return path.reverse();
}

function sourceContext(scene, path) {
  const layerIndex = path[0] === 'objects' && Number.isInteger(path[1]) ? path[1] : undefined;
  const layer = layerIndex === undefined ? undefined : scene.objects?.[layerIndex];
  const layerId = object(layer) ? layer.id : undefined;
  const direct = path.length === 4 && path[3] === 'script';
  const effect = path.length === 6 && path[2] === 'effects' && Number.isInteger(path[3]) && path[4] === 'visible' && path[5] === 'script';
  const particle=path.length===5&&path[2]==='instanceoverride'&&PARTICLE_SCRIPT_PROPERTIES.includes(path[3])&&path[4]==='script';
  const target = layerIndex === undefined ? path.slice(0,-1).join('.') : effect ? `effects[${path[3]}].visible` : path.slice(2,-1).join('.');
  const registered = object(layer) && ((direct && (SCENE_SCRIPT_PROPERTIES.includes(path[2]) || path[2] === 'text')) || effect||particle);
  if (!registered) return {layerId,target,registered:false,editable:false,reason:'Unregistered script-like metadata; native script semantics are unknown'};
  const state = inspectOwned(scene,{layerId,target});
  return {layerId,target,registered:true,editable:state.editable,...(state.reason ? {reason:state.reason} : {})};
}

function inspectOwned(scene, selection) {
  try { return stateOf(anchor(scene,selection)); }
  catch (error) { return {editable:false,reason:error.message}; }
}

export function listSceneScripts(scene) {
  const owned = copyTree(scene);
  if (!object(owned) || (owned.objects !== undefined && !Array.isArray(owned.objects))) throw new Error('Invalid scene objects');
  const found = [], stack = [{value:owned,path:null}];
  while (stack.length) {
    const {value,path} = stack.pop();
    if (path?.key === 'script') {
      const fullPath = structuralPath(path);
      found.push({...sourceContext(owned,fullPath),path:fullPath,source:value});
    }
    if (value === null || typeof value !== 'object') continue;
    const keys = Object.keys(value);
    // Emit and descend in JSON member order, including source-like metadata.
    for (let index = keys.length - 1; index >= 0; index--) {
      const key = keys[index], childPath = {parent:path,key:Array.isArray(value) ? Number(key) : key};
      stack.push({value:value[key],path:childPath});
    }
  }
  return found;
}
