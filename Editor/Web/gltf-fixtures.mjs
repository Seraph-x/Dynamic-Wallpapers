const encode=value=>new TextEncoder().encode(JSON.stringify(value));
export function gltfSource(json={asset:{version:'2.0'}},files=[]) {return {entry:'model.gltf',files:[{path:'model.gltf',bytes:encode(json)},...files]};}
export function glbBytes(json,bin,extras=[]) {
  const pad=(bytes,value)=>{const result=new Uint8Array(Math.ceil(bytes.length/4)*4).fill(value);result.set(bytes);return result;};
  const parts=[{type:0x4e4f534a,bytes:pad(encode(json),32)},...(bin?[{type:0x004e4942,bytes:pad(bin,0)}]:[]),...extras];
  const out=new Uint8Array(12+parts.reduce((n,p)=>n+8+p.bytes.length,0)),view=new DataView(out.buffer);view.setUint32(0,0x46546c67,true);view.setUint32(4,2,true);view.setUint32(8,out.length,true);
  let at=12;for(const part of parts){view.setUint32(at,part.bytes.length,true);view.setUint32(at+4,part.type,true);out.set(part.bytes,at+8);at+=8+part.bytes.length;}return out;
}
export function glbSource(json,bin,extras) {return {entry:'model.glb',files:[{path:'model.glb',bytes:glbBytes(json,bin,extras)}]};}
export function accessorSource(bytes,accessors,bufferViews=[{buffer:0,byteLength:bytes.length}]) {
  return gltfSource({asset:{version:'2.0'},buffers:[{uri:'data.bin',byteLength:bytes.length}],bufferViews,accessors},[{path:'data.bin',bytes}]);
}
export function rigGltf({duration=1}={}) {
  const buffers=[],bufferViews=[],accessors=[];let length=0;
  function accessor(array,type,componentType=5126){
    const bytes=new Uint8Array(array.buffer,array.byteOffset,array.byteLength),offset=Math.ceil(length/4)*4;buffers.push({offset,bytes});length=offset+bytes.length;
    const bufferView=bufferViews.length;bufferViews.push({buffer:0,byteOffset:offset,byteLength:bytes.length});const size={SCALAR:1,VEC2:2,VEC3:3,VEC4:4,MAT4:16}[type],min=Array(size).fill(Infinity),max=Array(size).fill(-Infinity);array.forEach((value,i)=>{min[i%size]=Math.min(min[i%size],value);max[i%size]=Math.max(max[i%size],value);});accessors.push({bufferView,componentType,count:array.length/size,type,min,max});return accessors.length-1;
  }
  const primitives=[[-35,0],[35,1]].map(([x,joint])=>({attributes:{
    POSITION:accessor(Float32Array.of(x-15,-15,0,x+15,-15,0,x+15,15,0,x-15,15,0),'VEC3'),
    TEXCOORD_0:accessor(Float32Array.of(0,1,1,1,1,0,0,0),'VEC2'),
    JOINTS_0:accessor(Uint8Array.from({length:16},(_,i)=>i%4===0?joint:0),'VEC4',5121),
    WEIGHTS_0:accessor(Float32Array.from({length:16},(_,i)=>i%4===0?1:0),'VEC4')},
    indices:accessor(Uint16Array.of(0,1,2,0,2,3),'SCALAR',5123),material:joint}));
  const translation=x=>[1,0,0,0,0,1,0,0,0,0,1,0,x,0,0,1];
  const inverseBindMatrices=accessor(Float32Array.from([...translation(35),...translation(-35)]),'MAT4');
  const input=accessor(Float32Array.of(0,duration),'SCALAR'),output=accessor(Float32Array.of(35,0,0,35,60,0),'VEC3');
  const data=new Uint8Array(length);for(const item of buffers)data.set(item.bytes,item.offset);
  const json={asset:{version:'2.0',generator:'Owned glTF acceptance'},scene:0,scenes:[{name:'Rig scene',nodes:[0]}],
    nodes:[{name:'Root',children:[1,2,3]},{name:'Left',translation:[-35,0,0]},{name:'Right',translation:[35,0,0]},{name:'Mesh',mesh:0,skin:0}],
    meshes:[{primitives}],skins:[{joints:[1,2],inverseBindMatrices}],
    materials:[[0,1,0,1],[0,0,1,1]].map(baseColorFactor=>({extensions:{KHR_materials_unlit:{}},doubleSided:true,pbrMetallicRoughness:{baseColorFactor}})),
    animations:[{name:'Move right',samplers:[{input,output,interpolation:'LINEAR'}],channels:[{sampler:0,target:{node:2,path:'translation'}}]}],
    accessors,bufferViews,buffers:[{uri:'rig.bin',byteLength:data.length}],extras:{future:{kept:true}}};
  return gltfSource(json,[{path:'rig.bin',bytes:data}]);
}
export function changeGltf(source,change) {const value=structuredClone(source),json=JSON.parse(new TextDecoder().decode(value.files[0].bytes));change(json,value);value.files[0].bytes=encode(json);return value;}
