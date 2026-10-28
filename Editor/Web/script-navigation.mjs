import { inspectSceneScript } from './script-source.mjs';
import {validateResourceSource} from './resource-source.mjs';
const fields=['documentIdentity','source','layerId','target','path','line','registered'];
export function validateScriptLink(link) {
 const keys=link&&typeof link==='object'&&!Array.isArray(link)?Object.keys(link):[];
 const external=keys.length===fields.length+1&&Object.hasOwn(link,'resource');
 if(!link||typeof link!=='object'||Array.isArray(link)||!(keys.length===fields.length||external)||fields.some(key=>!Object.hasOwn(link,key)))throw new Error('Invalid captured source link fields');
 if(typeof link.documentIdentity!=='string'||!link.documentIdentity||typeof link.source!=='string'||typeof link.target!=='string'||typeof link.registered!=='boolean'||!(link.layerId===null||typeof link.layerId==='number'&&Number.isFinite(link.layerId))||!(link.line===null||Number.isSafeInteger(link.line)&&link.line>0)||!Array.isArray(link.path)||!link.path.every(key=>typeof key==='string'||Number.isSafeInteger(key)&&key>=0))throw new Error('Invalid captured source link');
 const resource=external?validateResourceSource(link.resource):undefined;
 if(resource&&(link.source!==resource.text||link.path.length!==resource.pointer.length||link.path.some((value,index)=>value!==resource.pointer[index])||!link.registered))throw new Error('Invalid captured resource source link');
 return Object.freeze({...link,path:Object.freeze([...link.path]),...(resource?{resource}:{})});
}
export function resolveScriptLink(value,{scene,documentIdentity,pending=false}) {
 const link=validateScriptLink(value);
 const captured=reason=>({kind:'captured',reason,link});
 if(documentIdentity!==link.documentIdentity)return captured('document');
 if(link.resource)return captured('anchor');
 if(!link.registered||link.layerId===null)return captured('anchor');
 const current=inspectSceneScript(scene,{layerId:link.layerId,target:link.target});
 if(!Object.hasOwn(current,'source'))return captured('anchor');
 if(current.source!==link.source)return captured('source');
 if(!current.editable)return captured('anchor');
 if(pending)return captured('pending');
 return {kind:'current',link};
}
export function scriptLineSelection(source,line) {
 if(line===null)return {available:false,reason:'missing',line};
 // The upstream compiler removes import declarations without source maps.
 // Their transformed line cannot be claimed as an original-source location.
 const namespaceImport=/\bimport\s*\*\s*as\s+(\w+)\s+from\s*['"]([^'"]+)['"]\s*;?/;
 const hws='[ \t\u00a0\u3000\ufeff]',importLine=new RegExp(`(^${hws}*|;|\\})${hws}*import\\s+(?:[^;'"]+\\s+from\\s+)?['"][^'"]*['"];?${hws}*`,'m');
 if(namespaceImport.test(source)||importLine.test(source))return {available:false,reason:'transformed',line};
 const lines=source.replace(/\r\n?/g,'\n').split('\n');
 if(!Number.isSafeInteger(line)||line<1||line>lines.length)return {available:false,reason:'outside',line};
 const from=lines.slice(0,line-1).reduce((sum,text)=>sum+text.length+1,0);
 return {available:true,from,to:from+lines[line-1].length,line};
}
