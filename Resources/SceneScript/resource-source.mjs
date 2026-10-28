import {assertSourceString} from './json-spans.mjs';
import {inspectResourceScripts,resourceScriptPath} from './resource-contract.mjs';

const fields=['kind','path','sha256','pointer','text'];
export function validateResourceSource(value) {
 if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==fields.length||fields.some(key=>!Object.hasOwn(value,key)))throw new TypeError('Invalid resource source fields');
 if(value.kind!=='resource'||typeof value.sha256!=='string'||!/^[a-f0-9]{64}$/.test(value.sha256)||!Array.isArray(value.pointer))throw new TypeError('Invalid resource source identity');
 try{resourceScriptPath(value.path);assertSourceString(value.text);}catch(error){throw new TypeError(error.message,{cause:error});}
 for(const part of value.pointer){
  if(typeof part==='string')assertSourceString(part);
  else if(!Number.isSafeInteger(part)||part<0)throw new TypeError('Invalid resource source pointer');
 }
 return Object.freeze({...value,pointer:Object.freeze([...value.pointer])});
}

const rounds=Uint32Array.of(
 0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
 0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
 0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
 0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
 0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
 0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
 0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
 0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2);
const rotate=(value,bits)=>(value>>>bits)|(value<<(32-bits));
/** FIPS 180-4 SHA-256 over original bytes, including non-secure local HTTP origins. */
export function resourceSHA256(input) {
 if(!(input instanceof Uint8Array))throw new TypeError('Resource bytes required');
 const length=Math.ceil((input.length+9)/64)*64,bytes=new Uint8Array(length),view=new DataView(bytes.buffer);
 bytes.set(input);bytes[input.length]=0x80;
 view.setUint32(length-8,Math.floor(input.length/0x20000000));view.setUint32(length-4,input.length*8);
 const hash=Uint32Array.of(0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19),words=new Uint32Array(64);
 for(let offset=0;offset<length;offset+=64){
  for(let index=0;index<16;index++)words[index]=view.getUint32(offset+index*4);
  for(let index=16;index<64;index++){
   const a=words[index-15],b=words[index-2],s0=rotate(a,7)^rotate(a,18)^(a>>>3),s1=rotate(b,17)^rotate(b,19)^(b>>>10);
   words[index]=words[index-16]+s0+words[index-7]+s1;
  }
  let [a,b,c,d,e,f,g,h]=hash;
  for(let index=0;index<64;index++){
   const first=(h+(rotate(e,6)^rotate(e,11)^rotate(e,25))+((e&f)^(~e&g))+rounds[index]+words[index])>>>0;
   const second=((rotate(a,2)^rotate(a,13)^rotate(a,22))+((a&b)^(a&c)^(b&c)))>>>0;
   h=g;g=f;f=e;e=(d+first)>>>0;d=c;c=b;b=a;a=(first+second)>>>0;
  }
  for(const [index,value] of [a,b,c,d,e,f,g,h].entries())hash[index]+=value;
 }
 return [...hash].map(value=>value.toString(16).padStart(8,'0')).join('');
}

function objectAt(document,path) {
 let value=document;
 for(const part of path){if(!value||typeof value!=='object'||!Object.hasOwn(value,part))return undefined;value=value[part];}
 return value&&typeof value==='object'?value:undefined;
}
/** Private wrapper identities originate in actual parser inputs, never script-supplied properties. */
export function createResourceOrigins() {
 const wrappers=new WeakMap();
 function capture(path,input,document,kind) {
  resourceScriptPath(path);
  const bytes=new Uint8Array(input),sha256=resourceSHA256(bytes),reports=new Map();
  const reportFor=consumer=>{
   if(!reports.has(consumer))reports.set(consumer,inspectResourceScripts({path,bytes,kind,consumers:[{kind:consumer}]}));
   return reports.get(consumer);
  };
  for(const record of reportFor(kind==='particle'?'particle':'effect').records){
   const wrapper=objectAt(document,record.anchor);
   if(record.hasScript&&wrapper)wrappers.set(wrapper,{record,path,sha256,reportFor});
  }
  return document;
 }
 function script(wrapper,consumer) {
  const owned=wrappers.get(wrapper);if(!owned)return undefined;
  const anchor=JSON.stringify(owned.record.anchor),record=owned.reportFor(consumer).records.find(value=>value.registered&&JSON.stringify(value.anchor)===anchor);
  if(!record?.editable||!record.hasScript)return undefined;
  if(wrapper.script!==record.source)throw new Error('Resource source changed outside its captured origin');
  const source=validateResourceSource({kind:'resource',path:owned.path,sha256:owned.sha256,pointer:record.scriptPath,text:record.source});
  return Object.freeze({source,valueKind:record.valueKind});
 }
 return Object.freeze({capture,script,owns:wrapper=>wrappers.has(wrapper)});
}
