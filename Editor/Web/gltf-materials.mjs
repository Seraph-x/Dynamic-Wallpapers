import { gltfArray,gltfInteger } from './gltf-source.mjs';
import { finiteVector,gltfRef } from './gltf-validation.mjs';
import { solidPng,encodePng } from './vendor/gltf-png.mjs';
import { gltfImagePixels } from './gltf-image.mjs';
const json=value=>new TextEncoder().encode(JSON.stringify(value));
function image(source,image){
 if(!image||typeof image!=='object'||(image.uri!==undefined)===(image.bufferView!==undefined))throw new Error('glTF image needs exactly one URI or bufferView');
 const bytes=image.uri===undefined?source.view(image.bufferView).bytes.slice():source.readURI(image.uri);
 const png=[137,80,78,71,13,10,26,10].every((v,i)=>bytes[i]===v),jpg=bytes[0]===255&&bytes[1]===216&&bytes[2]===255;
 if(!png&&!jpg)throw new Error('Only PNG and JPEG glTF images are supported');
 const mime=png?'image/png':'image/jpeg';if(image.mimeType!==undefined&&image.mimeType!==mime)throw new Error('glTF image MIME type differs from supplied bytes');
 return {bytes,mime,extension:png?'png':'jpg'};
}
function uvSettings(source,info,notes,index){
 const textures=gltfArray(source.json,'textures'),texture=textures[gltfRef(info.index,textures,'base color texture')];
 const samplers=gltfArray(source.json,'samplers'),sampler=texture.sampler===undefined?{}:samplers[gltfRef(texture.sampler,samplers,'sampler')];
 for(const key of ['wrapS','wrapT'])if(sampler[key]!==undefined&&![33071,33648,10497].includes(sampler[key]))throw new Error('Invalid glTF texture wrapping');
 if(sampler.magFilter!==undefined&&![9728,9729].includes(sampler.magFilter))throw new Error('Invalid glTF magnification filter');
 if(sampler.minFilter!==undefined&&![9728,9729,9984,9985,9986,9987].includes(sampler.minFilter))throw new Error('Invalid glTF minification filter');
 const transform=info.extensions?.KHR_texture_transform??{},offset=finiteVector(transform.offset??[0,0],2,'texture offset'),scale=finiteVector(transform.scale??[1,1],2,'texture scale'),rotation=transform.rotation??0;
 if(!Number.isFinite(rotation))throw new Error('Invalid glTF texture rotation');
 const texCoord=gltfInteger(transform.texCoord??info.texCoord??0,'texture coordinate');
 notes.push({kind:'sampling',material:index,wrapS:sampler.wrapS??10497,wrapT:sampler.wrapT??10497,magFilter:sampler.magFilter??9729,minFilter:sampler.minFilter??9987});
 return {image:gltfRef(texture.source,gltfArray(source.json,'images'),'image'),uv:{texCoord,offset,scale,rotation}};
}
export function gltfMaterials(source,identifier){
 const images=gltfArray(source.json,'images').map(value=>image(source,value)),materials=gltfArray(source.json,'materials'),materialPaths=[],materialUVs=[],files=[],pending=[],notes=[];let requiresUnlitConsent=false,requiresTwoSidedConsent=false;
 for(const index of [-1,...materials.keys()]){
  const material=index<0?{}:materials[index];if(!material||typeof material!=='object'||Array.isArray(material))throw new Error('Invalid glTF material');
  const pbr=material.pbrMetallicRoughness??{},factor=finiteVector(pbr.baseColorFactor??[1,1,1,1],4,'base color factor');if(!factor.every(v=>v>=0&&v<=1))throw new Error('Invalid glTF base color factor range');
  const alphaMode=material.alphaMode??'OPAQUE',alphaCutoff=material.alphaCutoff??.5;if(!['OPAQUE','MASK','BLEND'].includes(alphaMode)||!Number.isFinite(alphaCutoff)||alphaCutoff<0)throw new Error('Invalid glTF alpha mode/cutoff');
  if(alphaMode==='BLEND')throw new Error('Unsupported glTF BLEND transparency: the pinned renderer cannot preserve transparent depth writes and sorting');
  if(material.doubleSided!==undefined&&typeof material.doubleSided!=='boolean')throw new Error('Invalid glTF doubleSided material');
  const defaultUsed=index<0&&gltfArray(source.json,'meshes').some(mesh=>gltfArray(mesh,'primitives').some(p=>p.material===undefined));
  if((index>=0||defaultUsed)&&!material.extensions?.KHR_materials_unlit){requiresUnlitConsent=true;notes.push({kind:'pbr',material:index,properties:Object.keys(material)});}
  if((index>=0||defaultUsed)&&material.doubleSided!==true){requiresTwoSidedConsent=true;notes.push({kind:'two-sided',material:index});}
  let look;if(pbr.baseColorTexture!==undefined){look=uvSettings(source,pbr.baseColorTexture,notes,index);materialUVs[index]=look.uv;}
  const slug=`${identifier}_${index<0?'default':index}`,path=`materials/editor/${slug}.json`,texturePath=`materials/editor/${slug}.png`;materialPaths[index]=path;
  const pass={defaultlight:false,blending:alphaMode==='OPAQUE'?'normal':'translucent',cullmode:'nocull',depthtest:'enabled',depthwrite:alphaMode==='BLEND'?'disabled':'enabled',shader:'generic4',textures:[`editor/${slug}`]};
  files.push({path,data:json({passes:[pass]})});
  if(look)pending.push({path:texturePath,...images[look.image],factor,alphaMode,alphaCutoff});
  else {const solid=factor.slice();if(alphaMode==='OPAQUE')solid[3]=1;else if(alphaMode==='MASK')solid[3]=solid[3]>=alphaCutoff?1:0;files.push({path:texturePath,data:solidPng(solid)});}
  if(alphaMode==='MASK')notes.push({kind:'mask',material:index,alphaCutoff});
 }
 return {images,materialPaths,materialUVs,files,pending,notes,requiresUnlitConsent,requiresTwoSidedConsent};
}
const linear=v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4;
const srgb=v=>Math.round(255*(v<=.0031308?12.92*v:1.055*v**(1/2.4)-.055));
export function bakeGltfPixels(input,{factor,alphaMode,alphaCutoff}){
 const out=input.slice();for(let at=0;at<out.length;at+=4){for(let c=0;c<3;c++)out[at+c]=srgb(linear(input[at+c]/255)*factor[c]);
 const alpha=input[at+3]/255*factor[3];out[at+3]=alphaMode==='OPAQUE'?255:alphaMode==='MASK'?(alpha>=alphaCutoff?255:0):Math.round(alpha*255);}
 return out;
}
export async function prepareGltfTextures(materials){
 const files=materials.files.map(file=>({path:file.path,data:file.data.slice()}));
 for(const item of materials.pending){
  const bitmap=await createImageBitmap(new Blob([item.bytes],{type:item.mime}),{premultiplyAlpha:'none',colorSpaceConversion:'none',imageOrientation:'none'});
  try{
   if(!bitmap.width||!bitmap.height)throw new Error('Decoded glTF image has no pixels');
   const pixels=gltfImagePixels(bitmap),bytes=encodePng(bitmap.width,bitmap.height,bakeGltfPixels(pixels,item));
   files.push({path:item.path,data:bytes});
  }finally{bitmap.close();}
 }
 return files;
}
