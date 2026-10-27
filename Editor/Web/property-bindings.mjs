import { createPropertyCatalog } from './property-catalog.mjs';

const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const own=(value,key)=>Object.hasOwn(value,key);
const finite=value=>typeof value==='number'&&Number.isFinite(value);
const defaults=Object.freeze({visible:true,alpha:1,color:'1 1 1',pointsize:24});
export const BINDING_FIELDS=Object.freeze(['visible','alpha','color','text','pointsize']);
const requireValue=(condition,message)=>{if(!condition)throw new Error(message);};

function anchor(document,selection){
  requireValue(object(document?.scene)&&object(selection),'Invalid binding selection');
  requireValue(BINDING_FIELDS.includes(selection.field),'Unsupported binding field');
  const layers=document.scene.objects??[];
  requireValue(Array.isArray(layers),'Invalid scene objects');
  const matches=layers.filter(layer=>object(layer)&&own(layer,'id')&&layer.id===selection.layerId);
  requireValue(matches.length===1,matches.length?'Ambiguous duplicate layer ID':'Layer does not exist');
  const layer=matches[0];
  requireValue(!['text','pointsize'].includes(selection.field)||own(layer,'text'),'Select a text layer');
  return layer;
}
function validBase(field,value){
  if(field==='visible')return typeof value==='boolean';
  if(field==='text')return typeof value==='string';
  if(field==='alpha')return finite(value)&&value>=0&&value<=1;
  if(field==='pointsize')return finite(value)&&value>0;
  if(field==='color'){
    const parts=typeof value==='string'?value.trim().split(/\s+/).map(Number):[];
    return parts.length===3&&parts.every(n=>Number.isFinite(n)&&n>=0&&n<=1);
  }
  return false;
}
// Match the unchanged renderer's valueShape/propShape decisions. In particular,
// a numeric-looking text base does not accept a textinput declaration on load.
function textShape(value){const parts=value.trim().split(/\s+/);return parts[0]!==''&&parts.every(part=>Number.isFinite(Number(part)))?'num':'text';}
function incompatibility(row,field,base){
  if(row.name==='')return 'The renderer cannot resolve an empty property identifier';
  if(row.readOnlyReason)return 'Read-only declaration: '+row.readOnlyReason;
  if(field==='visible')return ['bool','combo'].includes(row.type)?undefined:'Visibility requires a Boolean or choice property';
  if(field==='alpha'||field==='pointsize')return row.type==='slider'&&validBase(field,row.value)?undefined:'The numeric default is incompatible with this field';
  if(field==='color')return row.type==='color'?undefined:'Color requires an RGB color property';
  if(field==='text'){
    if(row.type==='textinput'&&textShape(base)==='text')return undefined;
    if(row.type==='combo'&&row.options.every(option=>textShape(option.value)===textShape(base)))return undefined;
    return 'The renderer cannot resolve this text property against the original base shape';
  }
  return 'Unsupported binding field';
}
function currentDescriptorError(user,row,field){
  if(field==='visible'&&row.type==='combo'){
    if(!object(user)||typeof user.condition!=='string'||!row.options.some(option=>option.value===user.condition))return 'The current visibility binding needs a declared choice condition';
  }else if(typeof user!=='string')return 'The current conditional descriptor is unsupported for this field';
  return undefined;
}
export function inspectPropertyBinding(document,selection){
  try{
    const layer=anchor(document,selection),field=selection.field,present=own(layer,field),raw=present?layer[field]:undefined;
    const wrapper=object(raw),base=wrapper?raw.value:present?raw:defaults[field];
    const controls=wrapper?['user','script','animation'].filter(key=>own(raw,key)):[],hasUser=wrapper&&own(raw,'user');
    if(!validBase(field,base))return structuredClone({field,present,raw,base,controls,hasUser,choices:[],reason:'Unsupported or missing binding base value'});
    let rows=[],metadataError;
    try{rows=createPropertyCatalog(document.project);}catch(error){metadataError=error.message;}
    const choices=rows.map(row=>({...row,incompatible:incompatibility(row,field,base)}));
    const currentName=typeof raw?.user==='string'?raw.user:object(raw?.user)?raw.user.name:undefined;
    const current=choices.find(row=>row.name===currentName);
    const currentError=hasUser?current?.incompatible??(!current?'Missing or unsupported property definition':currentDescriptorError(raw.user,current,field)):undefined;
    return structuredClone({field,present,raw,base,hasUser,choices,metadataError,currentName,currentError,
      controls,
      condition:object(raw?.user)?raw.user.condition:undefined});
  }catch(error){return {reason:error.message,choices:[],controls:[],hasUser:false};}
}
export function editPropertyBinding(document,edit){
  requireValue(object(edit)&&['bind','remove'].includes(edit.type),'Invalid binding edit');
  const state=inspectPropertyBinding(document,edit);requireValue(!state.reason,state.reason);
  const scene=structuredClone(document.scene),layer=anchor({...document,scene},edit);
  const wrapper=object(state.raw)?structuredClone(state.raw):{value:state.base};
  if(edit.type==='remove'){
    requireValue(state.hasUser,'This field has no user property binding');delete wrapper.user;
  }else{
    const row=state.choices.find(row=>row.name===edit.name);
    requireValue(row!==undefined,state.metadataError??'Property definition does not exist');
    requireValue(!row.incompatible,row.incompatible);
    requireValue(!state.controls.length||edit.replace===true,'Confirm replacement of the existing controls');
    if(edit.field==='visible'&&row.type==='combo'){
      requireValue(typeof edit.condition==='string'&&row.options.some(option=>option.value===edit.condition),'Select a declared choice condition');
      wrapper.user={name:edit.name,condition:edit.condition};
    }else{
      requireValue(edit.condition===undefined,'A direct binding cannot have a choice condition');wrapper.user=edit.name;
    }
    delete wrapper.script;delete wrapper.animation;
  }
  layer[edit.field]=Object.keys(wrapper).length===1&&own(wrapper,'value')?wrapper.value:wrapper;
  return scene;
}

export function assertPropertyBindingCapture(capture,{document,identity,name,message='The captured binding field or property definition changed'}){
  const same=(left,right)=>JSON.stringify(left)===JSON.stringify(right);
  const current=inspectPropertyBinding(document.snapshot(),capture.selection),state=capture.state;
  requireValue(capture.document===document&&capture.identity===identity&&current.present===state.present&&same(current.raw,state.raw),message);
  if(name!==undefined)requireValue(same(current.choices.find(row=>row.name===name)?.raw,state.choices.find(row=>row.name===name)?.raw),message);
}
