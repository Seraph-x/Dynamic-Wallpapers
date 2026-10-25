const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const clipID=value=>Number.isInteger(value)&&value>=0&&value<=0xffffffff;
const defaults={name:'',blend:1,rate:1,visible:true,additive:false};
const fields=new Set(['animation',...Object.keys(defaults)]);
const valid=(key,value)=>key==='animation'?clipID(value):key==='name'?typeof value==='string':['blend','rate'].includes(key)?Number.isFinite(value):typeof value==='boolean';
export function assertMixTable(table){
 if(!Array.isArray(table)||table.some(row=>!object(row)||!clipID(row.animation)))throw new Error('Controlled or unsupported animation-layer table');
 return table;
}
function rowValues(row){return Object.fromEntries([...fields].map(key=>[key,Object.hasOwn(row,key)?structuredClone(row[key]):defaults[key]]));}
function reason(row,clips){
 if([...fields].some(key=>Object.hasOwn(row,key)&&!valid(key,row[key])))return 'Controlled or unsupported animation-layer fields';
 if(!clips.some(clip=>clip.id===row.animation))return `Animation clip is unavailable: ${row.animation}`;
}
export function inspectMixLayers(table,clips){
 if(table===undefined||table===null||Array.isArray(table)&&!table.length)return {default:true,rows:[]};
 try{return {default:false,rows:assertMixTable(table).map((row,index)=>({index,values:rowValues(row),reason:reason(row,clips),raw:structuredClone(row)}))};}
 catch(error){return {default:false,rows:[],error:error.message};}
}
function indexAt(rows,index){if(!Number.isInteger(index)||index<0||index>=rows.length)throw new Error('Invalid animation-layer index');return index;}
function available(id,clips){if(!clipID(id)||!clips.some(clip=>clip.id===id))throw new Error('Animation clip is unavailable');}
export function editMixLayers(table,operation,clips){
 if(!object(operation))throw new Error('Expected animation-layer operation');
 const rows=structuredClone(table===undefined||table===null?[]:assertMixTable(table));
 if(operation.type==='add'){
  available(operation.clip,clips);if(operation.name!==undefined&&typeof operation.name!=='string')throw new Error('Invalid animation-layer name');
  rows.push({name:operation.name??'',animation:operation.clip,blend:1,rate:1,visible:true,additive:false});return rows;
 }
 const index=indexAt(rows,operation.index),row=rows[index];
 if(operation.type==='remove'){rows.splice(index,1);return rows;}
 if(operation.type==='move'){indexAt(rows,operation.to);rows.splice(operation.to,0,...rows.splice(index,1));return rows;}
 const unsupported=reason(row,clips);if(unsupported)throw new Error(unsupported);
 if(operation.type==='duplicate'){rows.splice(index+1,0,structuredClone(row));return rows;}
 if(operation.type!=='update'||!object(operation.values))throw new Error('Invalid animation-layer edit');
 const values=rowValues(row);
 for(const [key,value] of Object.entries(operation.values)){
  if(!fields.has(key)||!valid(key,value))throw new Error(`Invalid animation-layer ${key}`);
  if(key==='animation')available(value,clips);
  if(value!==values[key])row[key]=value;
 }
 return rows;
}
