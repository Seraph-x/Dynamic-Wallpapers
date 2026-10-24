import { encodeMDL } from './vendor/mdl-codec.mjs';
import { safePath } from './document.mjs';

const UINT32_MAX=0xffffffff,VERTEX_BYTES=80;
const identity=()=>Float32Array.of(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1);
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
export function imagePuppetStats({columns,rows}) {
  if(!Number.isSafeInteger(columns)||columns<1||!Number.isSafeInteger(rows)||rows<1)throw new Error('Grid cell counts must be positive safe integers');
  const vertices=(columns+1)*(rows+1),triangles=columns*rows*2,indexBytes=triangles*3*(vertices>65535?4:2),vertexBytes=vertices*VERTEX_BYTES;
  if(![vertices,triangles,indexBytes,vertexBytes].every(Number.isSafeInteger)||Math.max(vertices,indexBytes,vertexBytes)>UINT32_MAX)throw new Error('Grid exceeds native MDL 32-bit buffer representation');
  return {vertices,triangles,indexBytes,vertexBytes};
}
function validate(model,material,rootName) {
  if(!object(model)||Object.hasOwn(model,'puppet'))throw new Error('The source must be an image model without an existing puppet');
  if(model.autosize!==undefined&&model.autosize!==false)throw new Error('Autosized image models do not declare a supported natural size');
  if(![model.width,model.height].every(v=>Number.isFinite(v)&&v>0&&Number.isFinite(Math.fround(v))&&Math.fround(v/2)>0))throw new Error('Image model needs positive finite Float32-representable width and height');
  safePath(model.material);
  if(typeof rootName!=='string'||!rootName.trim()||rootName.includes('\0')||new TextDecoder().decode(new TextEncoder().encode(rootName))!==rootName)throw new Error('A valid root bone name is required');
  if(!object(material)||!Array.isArray(material.passes)||material.passes.length!==1)throw new Error('Only single-pass textured image materials can be converted');
  const pass=material.passes[0];
  if(!object(pass)||!['genericimage2','genericimage4'].includes(pass.shader)||!Array.isArray(pass.textures)||pass.textures.length!==1||typeof pass.textures[0]!=='string')throw new Error('Unsupported image material shader or texture layout');
  safePath(pass.textures[0]);
  if(pass.textures[0].startsWith('_rt_'))throw new Error('Render-target textures cannot be converted');
  for(const key of ['constantshadervalues','combos'])if(pass[key]!==undefined&&(!object(pass[key])||Object.keys(pass[key]).length))throw new Error('Material shader constants or combos cannot be flattened into this mesh');
  if(pass.bind!=null||pass.target!=null)throw new Error('Render-target bound image materials cannot be converted');
}
function dimensions(model,layerSize) {
  if(layerSize===undefined||layerSize===null||layerSize==='')return [model.width,model.height];
  if(object(layerSize)&&['user','script','animation'].some(key=>Object.hasOwn(layerSize,key)))throw new Error('Controlled image size cannot be converted to constant mesh geometry');
  const raw=object(layerSize)?layerSize.value:layerSize;
  if(typeof raw!=='string'&&typeof raw!=='number')throw new Error('Image layer size must declare constant dimensions');
  const values=String(raw).trim().split(/\s+/).map(Number),size=values.length===1?[values[0],values[0]]:values;
  if(size.length!==2||!size.every(Number.isFinite))throw new Error('Image layer size needs two finite dimensions');
  if(size.every(v=>v===0))return [model.width,model.height];
  if(!size.every(v=>v>0&&Number.isFinite(Math.fround(v))&&Math.fround(v/2)>0))throw new Error('Image layer size needs positive Float32-representable dimensions');
  return size;
}
function mesh(width,height,columns,rows,material) {
  const {vertices,triangles}=imagePuppetStats({columns,rows});
  const positions=new Float32Array(vertices*3),uvs=new Float32Array(vertices*2),boneIdx=new Uint32Array(vertices*4),weights=new Float32Array(vertices*4),indices=new Uint32Array(triangles*3);
  for(let y=0;y<=rows;y++)for(let x=0;x<=columns;x++){
    const i=y*(columns+1)+x;positions[i*3]=(x/columns-.5)*width;positions[i*3+1]=(.5-y/rows)*height;
    if((y===0&&x>0&&positions[i*3]<=positions[(i-1)*3])||(x===0&&y>0&&positions[i*3+1]>=positions[(i-columns-1)*3+1]))throw new Error('Grid spacing collapses in Float32 encoding');
    uvs[i*2]=x/columns;uvs[i*2+1]=y/rows;weights[i*4]=1;
  }
  let at=0;
  for(let y=0;y<rows;y++)for(let x=0;x<columns;x++){
    const a=y*(columns+1)+x,b=a+1,c=a+columns+1,d=c+1;indices.set([a,c,b,b,c,d],at);at+=6;
  }
  return {material,positions,uvs,boneIdx,weights,indices};
}
export function createImagePuppet({model,material,modelPath,mdlPath,materialPath,columns,rows,rootName,layerSize}) {
  validate(model,material,rootName);for(const path of [modelPath,mdlPath,materialPath])safePath(path);
  if(new Set([modelPath,mdlPath,materialPath].map(p=>p.normalize('NFC').toLowerCase())).size!==3)throw new Error('Mesh resource paths must be distinct');
  const stats=imagePuppetStats({columns,rows}),[width,height]=dimensions(model,layerSize);
  const bones=[{name:rootName,parent:-1,matrix:identity()}];
  const animations=[{id:1,name:'Rest',mode:'loop',fps:30,frameCount:1,tracks:[Float32Array.of(0,0,0,0,0,0,1,1,1,0,0,0,0,0,0,1,1,1)]}];
  // Compute exact variable-string/header overhead with the same encoder before
  // allocating a potentially large grid. MDL section offsets are native u32.
  const template=encodeMDL({bones,animations,meshes:[mesh(width,height,1,1,materialPath)]});
  const overhead=template.length-4*VERTEX_BYTES-6*2;
  if(overhead+stats.vertexBytes+stats.indexBytes>UINT32_MAX)throw new Error('Grid exceeds native MDL section offsets');
  const mdl=encodeMDL({bones,animations,meshes:[mesh(width,height,columns,rows,materialPath)]});
  const nextMaterial=structuredClone(material);nextMaterial.passes[0].defaultlight=false;
  const nextModel={...structuredClone(model),autosize:false,material:materialPath,puppet:mdlPath};
  const json=value=>new TextEncoder().encode(JSON.stringify(value));
  return {modelPath,mdlPath,materialPath,...stats,files:[{path:mdlPath,data:mdl},{path:materialPath,data:json(nextMaterial)},{path:modelPath,data:json(nextModel)}]};
}
