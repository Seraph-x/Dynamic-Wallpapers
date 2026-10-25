import { gltfArray,gltfInteger } from './gltf-source.mjs';
export const finiteVector=(value,size,label)=>{if(!Array.isArray(value)||value.length!==size||!value.every(Number.isFinite))throw new Error(`Invalid glTF ${label}`);return value.slice();};
export function gltfRef(value,array,label){const index=gltfInteger(value,label);if(index>=array.length)throw new Error(`Invalid glTF ${label} reference`);return index;}
export function gltfName(value,defaultName){const name=value===undefined?defaultName:value;if(typeof name!=='string'||name.includes('\0')||new TextDecoder().decode(new TextEncoder().encode(name))!==name)throw new Error('Unrepresentable glTF name');return name;}
export function quaternion(value){const q=finiteVector(Array.from(value),4,'quaternion'),length=Math.hypot(...q);if(!length||Math.abs(length-1)>1e-5)throw new Error('glTF quaternion must have unit length');return q.map(value=>value/length);}
export function float32(values,label){const result=Float32Array.from(values);if(!result.every(Number.isFinite))throw new Error(`glTF ${label} overflows Float32`);return result;}
export function validateGltfExtensions(json){
  const supported=new Set(['KHR_materials_unlit','KHR_mesh_quantization','KHR_texture_transform']);
  for(const key of ['extensionsUsed','extensionsRequired'])for(const extension of gltfArray(json,key))if(typeof extension!=='string'||!supported.has(extension))throw new Error(`Unsupported glTF extension: ${String(extension)}`);
  const visit=value=>{
    if(!value||typeof value!=='object')return;
    if(value.extensions!==undefined){if(!value.extensions||typeof value.extensions!=='object'||Array.isArray(value.extensions))throw new Error('Invalid glTF extensions');for(const [key,extension] of Object.entries(value.extensions)){if(!supported.has(key))throw new Error(`Unsupported glTF extension: ${key}`);if(!extension||typeof extension!=='object'||Array.isArray(extension))throw new Error(`Invalid glTF extension ${key}`);}}
    for(const [key,item] of Object.entries(value)){if(key==='extras'||key==='extensions')continue;if(Array.isArray(item))item.forEach(visit);else if(item&&typeof item==='object')visit(item);}
  };visit(json);
}
