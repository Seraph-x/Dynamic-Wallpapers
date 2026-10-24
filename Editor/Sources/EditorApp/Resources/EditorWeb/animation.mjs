const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const clone = value => structuredClone(value);
export const ANIMATED_PROPERTIES = Object.freeze({
  origin:Object.freeze({channels:3,initial:'0 0 0'}), scale:Object.freeze({channels:3,initial:'1 1 1'}),
  angles:Object.freeze({channels:3,initial:'0 0 0'}), color:Object.freeze({channels:3,initial:'1 1 1'}),
  alpha:Object.freeze({channels:1,initial:1}),
});
function info(property) {
  if (!Object.hasOwn(ANIMATED_PROPERTIES,property)) throw new Error('Unsupported animated property');
  return ANIMATED_PROPERTIES[property];
}
function components(value,property) {
  const values = info(property).channels === 1 ? [value] : typeof value === 'string' ? value.trim().split(/\s+/).map(Number) : value;
  if (!Array.isArray(values) || values.length !== info(property).channels || !values.every(Number.isFinite)) throw new Error('Invalid animation base value');
  return [...values];
}
function constant(value,property) {
  const values = components(value,property);
  for (const number of values) validValue(number,property);
  return values.length === 1 ? values[0] : values.join(' ');
}
function validValue(value,property) {
  if (!Number.isFinite(value) || (['color','alpha'].includes(property) && (value < 0 || value > 1))) throw new Error('Invalid key value');
}
function settings(options) {
  if (!object(options) || !Number.isFinite(Number(options.fps)) || Number(options.fps) <= 0 ||
      !Number.isFinite(Number(options.length)) || Number(options.length) <= 0 || !['single','loop','mirror'].includes(options.mode)) throw new Error('Invalid animation settings');
}
function checkKeys(keys,length) {
  if (!Array.isArray(keys) || !keys.length) throw new Error('An animation channel needs at least one key');
  let previous = -Infinity;
  for (const key of keys) {
    if (!object(key) || !Number.isFinite(key.frame) || key.frame < 0 || key.frame > length || key.frame <= previous || !Number.isFinite(key.value)) throw new Error('Unsupported keyframe data');
    previous = key.frame;
    for (const handle of [key.front,key.back]) if (handle?.enabled &&
      (!Number.isFinite(Number(handle.x ?? 0)) || !Number.isFinite(Number(handle.y ?? 0)))) throw new Error('Unsupported tangent data');
  }
}
export function animationState(layer,property) {
  const definition = info(property), raw = layer[property] ?? definition.initial;
  try {
    const base = components(object(raw) ? raw.value : raw,property);
    if (!object(raw)) return {kind:'constant',base};
    if (raw.script || raw.user !== undefined) return {kind:'bound',base,reason:'A script or user property controls this field'};
    if (!object(raw.animation)) return {kind:'bound',base,reason:'This field has an existing property binding'};
    const animation = raw.animation, options = animation.options;
    settings(options);
    if (options.startpaused === true || options.parent || options.children?.length) throw new Error('Linked or script-started animations must retain their existing control');
    if (animation.relative !== undefined && typeof animation.relative !== 'boolean') throw new Error('Unsupported relative animation flag');
    const channels = Array.from({length:definition.channels},(_,index) => animation[`c${index}`]);
    if (Object.keys(animation).some(key => /^c\d+$/.test(key) && Number(key.slice(1)) >= definition.channels)) throw new Error('Unsupported channel count');
    for (const channel of channels) checkKeys(channel,Number(options.length));
    return {kind:'animation',base,channels:clone(channels),options:clone(options),relative:animation.relative === true};
  } catch (error) { return {kind:'unsupported',reason:error.message}; }
}
export function keyInterpolation(key) {
  if (![key.front,key.back].some(handle => handle?.enabled)) return 'linear';
  if ([key.front,key.back].every(handle => handle?.enabled && Number(handle.x) === 1 && Number(handle.y) === 0)) return 'smooth';
  return 'custom';
}
function setInterpolation(key,mode) {
  if (mode === undefined) return;
  if (!['linear','smooth'].includes(mode)) throw new Error('Invalid interpolation');
  for (const side of ['front','back']) key[side] = mode === 'smooth'
    ? {...key[side],enabled:true,x:1,y:0} : {...key[side],enabled:false};
}
function create(layer,property,edit,state) {
  if (state.kind !== 'constant' && edit.replace !== true) throw new Error('Explicit binding replacement is required');
  settings(edit);
  const value = constant(edit.value ?? (state.kind === 'constant' ? layer[property] ?? info(property).initial : undefined),property);
  const base = components(value,property), wrapper = object(layer[property]) ? clone(layer[property]) : {};
  for (const key of ['script','scriptproperties','user','animation']) delete wrapper[key];
  return {...wrapper,value,animation:{...Object.fromEntries(base.map((number,index) => [`c${index}`,[{frame:0,value:number}]])),
    options:{fps:edit.fps,length:edit.length,mode:edit.mode}}};
}
function frame(value,length) {
  if (!Number.isFinite(value) || value < 0 || value > length) throw new Error('Key frame is outside the track duration');
  return value;
}
function keyEdit(wrapper,property,edit,state) {
  if (!Number.isInteger(edit.channel) || edit.channel < 0 || edit.channel >= info(property).channels) throw new Error('Invalid animation channel');
  const keys = wrapper.animation[`c${edit.channel}`], length = Number(state.options.length);
  const at = frame(edit.frame,length), index = keys.findIndex(key => key.frame === at);
  if (edit.type === 'delete-key') {
    if (index < 0) throw new Error('Key does not exist');
    if (keys.length === 1) throw new Error('Keep one reference key or remove the entire animation');
    keys.splice(index,1); return;
  }
  if (edit.type === 'move-key') {
    const source = keys.find(key => key.frame === edit.from);
    if (!source) throw new Error('Key does not exist');
    if (index >= 0 && edit.from !== at) throw new Error('A key already occupies that frame');
    source.frame = at;
  } else if (['set-key','paste-key'].includes(edit.type)) {
    const paste = edit.type === 'paste-key';
    if (paste && (index >= 0 || !object(edit.key))) throw new Error('Cannot paste at an occupied frame');
    const absolute = paste ? edit.key.value : edit.value;
    validValue(absolute,property);
    const key = paste ? clone(edit.key) : index >= 0 ? keys[index] : {};
    key.frame = at; key.value = absolute - (state.relative ? state.base[edit.channel] : 0);
    setInterpolation(key,edit.interpolation);
    if (index < 0) keys.push(key);
  } else throw new Error('Unknown key operation');
  keys.sort((a,b) => a.frame-b.frame); checkKeys(keys,length);
}
export function editAnimation(layer,property,edit) {
  const state = animationState(layer,property);
  if (!object(edit)) throw new Error('Invalid animation edit');
  if (edit.type === 'create') return create(layer,property,edit,state);
  if (state.kind !== 'animation') throw new Error(state.reason ?? 'Create an animation first');
  const wrapper = clone(layer[property]);
  if (edit.type === 'remove') {
    delete wrapper.animation; wrapper.value = constant(edit.value,property);
    return Object.keys(wrapper).length === 1 ? wrapper.value : wrapper;
  }
  if (edit.type === 'settings') {
    settings(edit);
    for (const channel of state.channels) if (channel.some(key => key.frame > edit.length)) throw new Error('Move or remove later keys before shortening the track');
    if (state.options.events?.some(event => event.frame > edit.length)) throw new Error('Move animation events before shortening the track');
    Object.assign(wrapper.animation.options,{fps:edit.fps,length:edit.length,mode:edit.mode});
  } else keyEdit(wrapper,property,edit,state);
  return wrapper;
}
