export const RESOURCE_SCRIPT_UNAVAILABLE=Symbol('resource-script-unavailable');
const coordinates=['x','y','z','w'];
const overrideKinds=new Map([...'rate count size speed lifetime brightness alpha'.split(' ').map(key=>[key,'scalar']),['colorn','vector3']]);
export const particleOverrideValueKind=key=>overrideKinds.get(key);

function components(value,kind) {
 if(kind==='scalar'){
  if(typeof value!=='number'||!Number.isFinite(value))throw new TypeError('Resource script must produce a finite scalar');
  return value;
 }
 const count=Number(kind.slice(6)),parts=Array.isArray(value)?value:coordinates.slice(0,count).map(key=>value?.[key]);
 if(parts.length!==count||parts.some(part=>typeof part!=='number'||!Number.isFinite(part)))throw new TypeError(`Resource script must produce a finite ${kind}`);
 if(!Array.isArray(value)&&coordinates.slice(count).some(key=>value?.[key]!==undefined&&!(kind==='vector2'&&key==='z'&&value[key]===0)))throw new TypeError(`Resource script returned the wrong ${kind} dimension`);
 return parts;
}
function baseValue(wrapper,kind) {
 const raw=wrapper.value;
 return kind==='scalar'?components(raw,kind):components(typeof raw==='string'?raw.trim().split(/[\s,]+/).map(Number):raw,kind);
}
function argument(value,kind,vector) {
 if(kind==='scalar')return value;
 return vector?vector(kind,value):Object.fromEntries(coordinates.slice(0,value.length).map((key,index)=>[key,value[index]]));
}
function ownedTimers(environment,issue) {
 const handles=new Map();
 const add=(repeating,callback,delay)=>{
  const set=repeating?environment.setInterval:environment.setTimeout,clear=repeating?environment.clearInterval:environment.clearTimeout;
  if(typeof set!=='function'||typeof clear!=='function')throw new Error('Resource script engine timers are unavailable');
  const handle=set(()=>{
   if(!repeating)handles.delete(handle);
   try{callback();}catch(error){issue(error,'timer');throw error;}
  },delay);
  handles.set(handle,clear);return handle;
 };
 const cancel=handle=>{const clear=handles.get(handle);if(clear){handles.delete(handle);clear(handle);}};
 return {setTimeout:(callback,delay)=>add(false,callback,delay),setInterval:(callback,delay)=>add(true,callback,delay),clearTimeout:cancel,clearInterval:cancel,
  dispose(){for(const [handle,clear] of handles)clear(handle);handles.clear();}};
}

/** Every state belongs to an actual engine consumer, source wrapper and slot. */
export function createResourceScriptRuntime({origins,evaluate,environment,onIssue,onSandbox=()=>{},onDispose=()=>{},vector,scripts=true}) {
 const consumers=new Map(),states=new Set();let disposed=false;
 function definition(wrapper,context) {
  if(origins.owns(wrapper))return origins.script(wrapper,context.kind);
  if(!context.inline||!wrapper||typeof wrapper.script!=='string'||Object.hasOwn(wrapper,'user')||Object.hasOwn(wrapper,'animation'))return undefined;
  const valueKind=particleOverrideValueKind(context.key);return valueKind?{source:null,valueKind}:undefined;
 }
 function accept(state,result,phase) {
  if(result===undefined)return true;
  try{state.current=argument(components(result,state.definition.valueKind),state.definition.valueKind,vector);return true;}
  catch(error){state.issue(error,phase);return false;}
 }
 function start(wrapper,context,definition,frame) {
  const state={wrapper,context,definition,failed:false,sandbox:null,timers:null};
  state.issue=(error,phase)=>{state.failed=true;onIssue({...context,error,phase,source:definition.source});};
  states.add(state);
  try{
   state.current=argument(baseValue(wrapper,definition.valueKind),definition.valueKind,vector);
   const env=environment({...context,source:definition.source});state.timers=ownedTimers(env,state.issue);
   const sandbox=evaluate(wrapper.script,wrapper.scriptproperties||wrapper.scriptProperties||null,{...env,...state.timers,onError:state.issue});
   if(!sandbox){if(!state.failed)state.issue(new Error('Resource script has no executable entry'),'parse');return state;}
   state.sandbox=sandbox;Object.assign(sandbox.engine,frame);
   const initial=sandbox.init(state.current);
   if(!state.failed)accept(state,initial,'init');
   sandbox.applyUserProperties(env.userProperties||{});
   onSandbox({sandbox,layer:context.layer,read:()=>state.current,accept:result=>accept(state,result,'anim')});
  }catch(error){state.issue(error,'parse');}
  return state;
 }
 function value(wrapper,context,frame) {
  if(disposed)throw new Error('Resource script runtime is disposed');
  if(!scripts)return wrapper;
  let def;
  try{def=definition(wrapper,context);}catch(error){onIssue({...context,error,phase:'origin',source:null});return RESOURCE_SCRIPT_UNAVAILABLE;}
  if(!def)return wrapper;
  if(!context.consumer||typeof context.consumer!=='object')throw new TypeError('Resource script consumer identity is required');
  let layerConsumers=consumers.get(context.layer);if(!layerConsumers){layerConsumers=new Map();consumers.set(context.layer,layerConsumers);}
  let slots=layerConsumers.get(context.consumer);if(!slots){slots=new Map();layerConsumers.set(context.consumer,slots);}
  let wrappers=slots.get(context.slot);if(!wrappers){wrappers=new Map();slots.set(context.slot,wrappers);}
  let state=wrappers.get(wrapper);
  if(!state){state=start(wrapper,context,def,frame);wrappers.set(wrapper,state);if(state.failed)return RESOURCE_SCRIPT_UNAVAILABLE;}
  const sandbox=state.sandbox;if(!sandbox||sandbox.disabled||sandbox.entryDisabled?.update)return RESOURCE_SCRIPT_UNAVAILABLE;
  state.failed=false;Object.assign(sandbox.engine,frame);
  if(sandbox.hasUpdate){
   const returned=sandbox.callUpdate(state.current);
   if(state.failed||!accept(state,returned,'update'))return RESOURCE_SCRIPT_UNAVAILABLE;
  }
  const result=components(state.current,def.valueKind);return Array.isArray(result)?result.join(' '):result;
 }
 function constants(input,context,frame) {
  const result={...input};
  for(const [key,wrapper] of Object.entries(input??{}))if(wrapper&&typeof wrapper==='object'&&origins.owns(wrapper))result[key]=value(wrapper,{...context,key,target:`constantshadervalues.${key}`},frame);
  return result;
 }
 function drop(state) {
  if(state.sandbox){state.sandbox.disabled=true;onDispose(state.sandbox,state.context.layer);}
  state.timers?.dispose();states.delete(state);
 }
 function disposeLayers(ids) {
  for(const state of [...states])if(ids.has(state.context.layer?.id))drop(state);
  for(const layer of [...consumers.keys()])if(ids.has(layer?.id))consumers.delete(layer);
 }
 function dispose(){if(disposed)return;disposed=true;for(const state of [...states])drop(state);consumers.clear();}
 function applyUserProperties(properties){for(const state of states)state.sandbox?.applyUserProperties(properties||{});}
 return Object.freeze({value,constants,applyUserProperties,disposeLayers,dispose});
}

const particleValues=new WeakMap();
export const setResourceParticleConstants=(system,constants)=>particleValues.set(system,constants);
export const resourceParticleConstants=system=>particleValues.get(system);
