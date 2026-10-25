import { gltfArray,gltfInteger } from './gltf-source.mjs';
import { readGltfAccessor } from './gltf-accessors.mjs';
import { float32,finiteVector,gltfRef,validateGltfExtensions } from './gltf-validation.mjs';
import { ident,invert,mul } from './vendor/gltf-math.mjs';

const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const point=(matrix,x,y,z)=>[matrix[0]*x+matrix[4]*y+matrix[8]*z+matrix[12],matrix[1]*x+matrix[5]*y+matrix[9]*z+matrix[13],matrix[2]*x+matrix[6]*y+matrix[10]*z+matrix[14]];
const determinant=m=>m[0]*(m[5]*m[10]-m[6]*m[9])-m[4]*(m[1]*m[10]-m[2]*m[9])+m[8]*(m[1]*m[6]-m[2]*m[5]);

function positionBounds(source,index,accessor) {
  const definition=source.json.accessors[index],declared=['min','max'].map(key=>finiteVector(definition[key],3,`POSITION ${key} bounds`));
  let raw=accessor;
  if(accessor.normalized){const accessors=source.json.accessors.map((value,i)=>i===index?{...value,normalized:false}:value);raw=readGltfAccessor({...source,json:{...source.json,accessors}},index);}
  const minimum=[Infinity,Infinity,Infinity],maximum=[-Infinity,-Infinity,-Infinity],ranges={5120:[-128,127],5121:[0,255],5122:[-32768,32767],5123:[0,65535]};
  for(let i=0;i<raw.data.length;i++){const axis=i%3,value=raw.data[i];minimum[axis]=Math.min(minimum[axis],value);maximum[axis]=Math.max(maximum[axis],value);}
  declared.forEach((values,side)=>values.forEach((value,axis)=>{
    const float=accessor.componentType===5126,range=ranges[accessor.componentType],actual=side?maximum[axis]:minimum[axis],expected=float?Math.fround(value):value;
    if(!Number.isFinite(expected)||(!float&&(!Number.isInteger(value)||value<range[0]||value>range[1]))||expected!==actual)throw new Error(`glTF POSITION ${side?'max':'min'} bounds do not match decoded data`);
  }));
}

function attribute(source,index,semantic,count,quantized) {
  const value=readGltfAccessor(source,index),{type,componentType:component,normalized}=value;
  const floating=component===5126&&!normalized,small=[5120,5121,5122,5123].includes(component);
  let valid=false;
  if(semantic==='POSITION')valid=type==='VEC3'&&(floating||(quantized&&small));
  else if(semantic==='NORMAL'||semantic==='TANGENT')valid=type===(semantic==='NORMAL'?'VEC3':'VEC4')&&(floating||(quantized&&[5120,5122].includes(component)&&normalized));
  else if(semantic.startsWith('TEXCOORD_'))valid=type==='VEC2'&&(floating||([5121,5123].includes(component)&&normalized)||(quantized&&small));
  else if(semantic.startsWith('JOINTS_'))valid=type==='VEC4'&&[5121,5123].includes(component)&&!normalized;
  else if(semantic.startsWith('WEIGHTS_'))valid=type==='VEC4'&&(floating||([5121,5123].includes(component)&&normalized));
  if(!valid)throw new Error(`Unsupported glTF ${semantic} accessor type/component/normalization`);
  if(count!==undefined&&value.count!==count)throw new Error(`glTF ${semantic} accessor count differs from POSITION`);
  const definition=source.json.accessors[index],width={5120:1,5121:1,5122:2,5123:2,5126:4}[component];
  if(definition.bufferView!==undefined){const view=source.view(definition.bufferView);if((definition.byteOffset??0)%4||(view.byteStride??value.size*width)%4)throw new Error(`glTF ${semantic} vertex alignment must be four bytes`);}
  if(semantic==='POSITION')positionBounds(source,index,value);
  return value;
}

function triangleIndices(source,primitive,count,reflected) {
  let indices;
  if(primitive.indices===undefined)indices=Uint32Array.from({length:count},(_,i)=>i);
  else {
    const accessor=readGltfAccessor(source,primitive.indices);
    if(accessor.type!=='SCALAR'||![5121,5123,5125].includes(accessor.componentType)||accessor.normalized)throw new Error('Invalid glTF triangle index accessor');
    const definition=source.json.accessors[primitive.indices];if(definition.bufferView!==undefined&&source.view(definition.bufferView).byteStride!==undefined)throw new Error('glTF triangle index buffer cannot have byteStride');
    const restart={5121:255,5123:65535,5125:4294967295}[accessor.componentType];if(accessor.data.includes(restart))throw new Error('glTF triangle index uses a forbidden primitive restart value');
    if(accessor.data.some(index=>!Number.isInteger(index)||index<0||index>=count))throw new Error('glTF triangle index is outside vertex range');
    indices=Uint32Array.from(accessor.data);
  }
  if(indices.length%3!==0)throw new Error('glTF triangle index/vertex count must be divisible by three');
  if(reflected)for(let i=0;i<indices.length;i+=3)[indices[i+1],indices[i+2]]=[indices[i+2],indices[i+1]];
  return indices;
}

function directions(accessor,matrix,normal) {
  const inverse=normal?invert(matrix):undefined;if(normal&&!inverse)throw new Error('Singular glTF normal transform');
  const result=new Float64Array(accessor.data.length),size=accessor.size;
  for(let i=0;i<accessor.count;i++) {
    const [x,y,z]=accessor.data.subarray(i*size,i*size+3),length=Math.hypot(x,y,z);
    if(!length)throw new Error(`glTF ${normal?'normal':'tangent'} has zero length`);
    const xyz=normal?[inverse[0]*x+inverse[1]*y+inverse[2]*z,inverse[4]*x+inverse[5]*y+inverse[6]*z,inverse[8]*x+inverse[9]*y+inverse[10]*z]:[
      matrix[0]*x+matrix[4]*y+matrix[8]*z,matrix[1]*x+matrix[5]*y+matrix[9]*z,matrix[2]*x+matrix[6]*y+matrix[10]*z];
    const transformedLength=Math.hypot(...xyz);if(!transformedLength||!Number.isFinite(transformedLength))throw new Error('Invalid glTF transformed normal/tangent');
    result.set(xyz.map(value=>value/transformedLength),i*size);
    if(!normal){const w=accessor.data[i*size+3];if(w!==1&&w!==-1)throw new Error('glTF tangent handedness must be +1 or -1');result[i*size+3]=w*(determinant(matrix)<0?-1:1);}
  }
  return float32(result,normal?'normal':'tangent');
}

function uvTransform(accessor,descriptor) {
  if(!descriptor)return float32(accessor.data,'texture coordinate');
  const offset=finiteVector(descriptor.offset??[0,0],2,'texture offset'),scale=finiteVector(descriptor.scale??[1,1],2,'texture scale'),rotation=descriptor.rotation??0;
  if(!Number.isFinite(rotation))throw new Error('Invalid glTF texture rotation');
  const result=new Float64Array(accessor.data.length),c=Math.cos(rotation),s=Math.sin(rotation);
  for(let i=0;i<accessor.count;i++){const u=accessor.data[i*2]*scale[0],v=accessor.data[i*2+1]*scale[1];result[i*2]=offset[0]+c*u-s*v;result[i*2+1]=offset[1]+s*u+c*v;}
  return float32(result,'transformed texture coordinate');
}

function skinAttributes(source,attributes,count,nodeIndex,skeleton,quantized) {
  const skinIndex=skeleton.nodes[nodeIndex].skin,sets=new Set();
  for(const key of Object.keys(attributes))if(/^(JOINTS|WEIGHTS)_\d+$/.test(key))sets.add(Number(key.slice(key.indexOf('_')+1)));
  const boneIdx=new Uint32Array(count*4),weights=new Float32Array(count*4);
  if(skinIndex===undefined) {
    if(sets.size)throw new Error('glTF rigid mesh has skin attributes without a skin');
    for(let i=0;i<count;i++){boneIdx[i*4]=skeleton.boneOf.get(nodeIndex);weights[i*4]=1;}
    return {boneIdx,weights};
  }
  const joints=skeleton.skins[skinIndex].joints,ordered=[...sets].sort((a,b)=>a-b);
  if(!ordered.length)throw new Error('glTF skinned primitive requires paired JOINTS_0 and WEIGHTS_0');
  const pairs=ordered.map((set,i)=>{
    if(set!==i||attributes[`JOINTS_${set}`]===undefined||attributes[`WEIGHTS_${set}`]===undefined)throw new Error('glTF skin attributes must be consecutive paired JOINTS_n and WEIGHTS_n');
    return [attribute(source,attributes[`JOINTS_${set}`],`JOINTS_${set}`,count,quantized),attribute(source,attributes[`WEIGHTS_${set}`],`WEIGHTS_${set}`,count,quantized)];
  });
  for(let i=0;i<count;i++) {
    const influences=new Map();
    for(const [indices,values] of pairs)for(let k=0;k<4;k++) {
      const at=i*4+k,joint=indices.data[at],weight=values.data[at];gltfRef(joint,joints,'vertex joint');
      if(weight<0)throw new Error('glTF skin weight cannot be negative');if(weight===0)continue;
      const bone=skeleton.boneOf.get(joints[joint]);influences.set(bone,(influences.get(bone)??0)+weight);
    }
    if(influences.size>4)throw new Error('glTF vertex requires more than four positive bone influences');
    const sum=[...influences.values()].reduce((a,b)=>a+b,0);if(!(sum>0)||!Number.isFinite(sum))throw new Error('glTF vertex skin weights must have a positive finite total');
    let k=0;for(const [bone,value] of influences){const weight=Math.fround(value/sum);if(weight===0)throw new Error('glTF positive skin influence underflows Float32');boneIdx[i*4+k]=bone;weights[i*4+k]=weight;k++;}
  }
  return {boneIdx,weights};
}

function primitiveMesh(source,skeleton,nodeIndex,primitive,options) {
  if(!object(primitive)||!object(primitive.attributes))throw new Error('Invalid glTF primitive attributes');
  if(primitive.targets!==undefined)throw new Error('Unsupported glTF morph targets');
  if((primitive.mode??4)!==4)throw new Error(`Unsupported glTF primitive mode: ${String(primitive.mode)}`);
  const material=primitive.material===undefined?-1:gltfRef(primitive.material,gltfArray(source.json,'materials'),'material');
  const path=options.materialPaths?.[material];if(typeof path!=='string'||!path)throw new Error('Missing converted glTF material path');
  const descriptor=options.materialUVs?.[material];if(descriptor!==undefined&&!object(descriptor))throw new Error('Invalid glTF texture coordinate transform');
  const uvSet=descriptor?gltfInteger(descriptor.texCoord??0,'texture coordinate set'):0,uvKey=`TEXCOORD_${uvSet}`,attributes=primitive.attributes;
  for(const semantic of Object.keys(attributes))if(!['POSITION','NORMAL','TANGENT','TEXCOORD_0',...(descriptor?[uvKey]:[])].includes(semantic)&&!/^(JOINTS|WEIGHTS)_(0|[1-9]\d*)$/.test(semantic))throw new Error(`Unsupported glTF vertex attribute: ${semantic}`);
  if(attributes.POSITION===undefined)throw new Error('Missing glTF POSITION attribute');
  const quantized=gltfArray(source.json,'extensionsUsed').includes('KHR_mesh_quantization')||gltfArray(source.json,'extensionsRequired').includes('KHR_mesh_quantization');
  const position=attribute(source,attributes.POSITION,'POSITION',undefined,quantized),count=position.count,node=skeleton.nodes[nodeIndex],rigid=node.skin===undefined;
  // A rigid mesh node can also be a joint whose inverse bind differs from rest world.
  // Its vertices must use that bind so the renderer's world * inverse-bind acts once.
  const matrix=rigid?skeleton.bind.get(nodeIndex):ident(),positions=new Float64Array(count*3);
  for(let i=0;i<count;i++)positions.set(point(matrix,...position.data.subarray(i*3,i*3+3)).map(value=>value*options.scale),i*3);
  const mesh={material:path,positions:float32(positions,'position'),indices:triangleIndices(source,primitive,count,rigid&&determinant(skeleton.world.get(nodeIndex))<0),...skinAttributes(source,attributes,count,nodeIndex,skeleton,quantized)};
  if(attributes.NORMAL!==undefined)mesh.normals=directions(attribute(source,attributes.NORMAL,'NORMAL',count,quantized),matrix,true);
  if(attributes.TANGENT!==undefined)mesh.tangents=directions(attribute(source,attributes.TANGENT,'TANGENT',count,quantized),matrix,false);
  // MDL has one active UV channel. Unused secondary channels cannot be silently dropped.
  if(uvSet!==0&&attributes.TEXCOORD_0!==undefined)attribute(source,attributes.TEXCOORD_0,'TEXCOORD_0',count,quantized);
  if(descriptor&&attributes[uvKey]===undefined)throw new Error(`Missing glTF ${uvKey} texture coordinate attribute`);
  if(attributes[uvKey]!==undefined)mesh.uvs=uvTransform(attribute(source,attributes[uvKey],uvKey,count,quantized),descriptor);
  return mesh;
}

function extendBounds(bounds,mesh,skeleton,scale) {
  const matrices=new Map();
  for(const node of skeleton.order){const inverse=invert(skeleton.bind.get(node));if(!inverse)throw new Error('Singular glTF bind matrix');matrices.set(skeleton.boneOf.get(node),mul(skeleton.world.get(node),inverse));}
  for(let i=0;i<mesh.positions.length/3;i++) {
    const original=Array.from(mesh.positions.subarray(i*3,i*3+3),value=>value/scale),xyz=[0,0,0];
    for(let k=0;k<4;k++){const weight=mesh.weights[i*4+k];if(!weight)continue;const transformed=point(matrices.get(mesh.boneIdx[i*4+k]),...original);for(let axis=0;axis<3;axis++)xyz[axis]+=transformed[axis]*scale*weight;}
    const value=float32(xyz,'rest-world position');for(let axis=0;axis<3;axis++){bounds[axis]=Math.min(bounds[axis],value[axis]);bounds[axis+3]=Math.max(bounds[axis+3],value[axis]);}
  }
}

/** Convert every selected-scene triangle primitive. materialUVs entries are optional
 * {texCoord,offset,scale,rotation} descriptors for textured materials, including [-1]. */
export function gltfGeometry(source,skeleton,{scale,materialPaths,materialUVs}={}) {
  if(!Number.isFinite(scale)||scale<=0)throw new Error('Invalid glTF geometry scale');
  validateGltfExtensions(source.json);
  const meshes=[],bounds=[Infinity,Infinity,Infinity,-Infinity,-Infinity,-Infinity];
  for(const nodeIndex of skeleton.meshNodes) {
    const node=skeleton.nodes[nodeIndex],mesh=skeleton.meshes[node.mesh];
    if(node.weights!==undefined||mesh.weights!==undefined)throw new Error('Unsupported glTF morph weights');
    const primitives=gltfArray(mesh,'primitives');if(!primitives.length)throw new Error('glTF mesh contains no primitives');
    for(const primitive of primitives){const converted=primitiveMesh(source,skeleton,nodeIndex,primitive,{scale,materialPaths,materialUVs});meshes.push(converted);extendBounds(bounds,converted,skeleton,scale);}
  }
  if(!meshes.length)throw new Error('Selected glTF scene contains no mesh primitives');
  return {meshes,bounds};
}
