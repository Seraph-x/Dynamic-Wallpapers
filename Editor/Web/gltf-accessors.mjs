import { gltfArray,gltfInteger } from './gltf-source.mjs';
const types={SCALAR:[1,1],VEC2:[1,2],VEC3:[1,3],VEC4:[1,4],MAT2:[2,2],MAT3:[3,3],MAT4:[4,4]},components={5120:[1,'getInt8',127],5121:[1,'getUint8',255],5122:[2,'getInt16',32767],5123:[2,'getUint16',65535],5125:[4,'getUint32'],5126:[4,'getFloat32']};
function bounds(view,offset,count,step,length,alignment) {
  gltfInteger(offset,'accessor byte offset');
  if(offset%alignment||(view.offset+offset)%alignment||!Number.isSafeInteger(offset+(count-1)*step+length)||offset+(count-1)*step+length>view.bytes.length)throw new Error('glTF accessor alignment or view bounds invalid');
}
export function readGltfAccessor(source,index) {
  const accessor=gltfArray(source.json,'accessors')[gltfInteger(index,'accessor index')];if(!accessor||typeof accessor!=='object')throw new Error('Missing glTF accessor');
  const shape=types[accessor.type],component=components[accessor.componentType],count=gltfInteger(accessor.count,'accessor count',1);
  if(!shape||!component)throw new Error('Unsupported glTF accessor type/component');
  const [columns,rows]=shape,[width,method,maximum]=component,size=columns*rows,columnBytes=columns>1?Math.ceil(rows*width/4)*4:rows*width,length=columns*columnBytes;
  const lastLength=(columns-1)*columnBytes+rows*width;
  // MDL buffers use 32-bit byte lengths. Reject an unencodable allocation,
  // including sparse zero-filled data, before constructing a dense typed array.
  if(!Number.isSafeInteger(count*size*4)||count*size*4>0xffffffff)throw new Error('glTF accessor exceeds native MDL byte representation');
  if(accessor.normalized!==undefined&&typeof accessor.normalized!=='boolean')throw new Error('Invalid glTF accessor normalization');
  if(accessor.normalized&&(accessor.componentType===5125||accessor.componentType===5126))throw new Error('Invalid glTF accessor normalization component');
  const normalized=accessor.normalized===true;
  function value(view,offset){const result=view[method](offset,true);if(!Number.isFinite(result))throw new Error('glTF accessor contains a nonfinite value');return normalized?Math.max(-1,result/maximum):result;}
  function readElement(view,offset,destination,at){for(let c=0;c<columns;c++)for(let r=0;r<rows;r++){const component=value(view,offset+c*columnBytes+r*width);if(destination)destination[at+c*rows+r]=component;}}
  let base,sparseLayout;
  if(accessor.bufferView!==undefined){
    const view=source.view(accessor.bufferView),step=view.byteStride??length,offset=accessor.byteOffset??0;
    if(step<length||step%width)throw new Error('Invalid glTF accessor stride');bounds(view,offset,count,step,lastLength,columns>1?Math.max(4,width):width);
    const bytes=new DataView(view.bytes.buffer,view.bytes.byteOffset,view.bytes.length);base={bytes,offset,step};
  }else if((accessor.byteOffset??0)!==0)throw new Error('An accessor without a view cannot have a byte offset');
  if(accessor.sparse!==undefined){
    const sparse=accessor.sparse,n=gltfInteger(sparse?.count,'sparse count',1);if(n>count||!sparse.indices||!sparse.values)throw new Error('Invalid glTF sparse metadata');
    const indices=source.view(sparse.indices.bufferView),values=source.view(sparse.values.bufferView),component=components[sparse.indices.componentType];
    if(![5121,5123,5125].includes(sparse.indices.componentType)||indices.byteStride!==undefined||values.byteStride!==undefined)throw new Error('Invalid glTF sparse index type/stride');
    const [indexWidth,indexMethod]=component,io=sparse.indices.byteOffset??0,vo=sparse.values.byteOffset??0;
    bounds(indices,io,n,indexWidth,indexWidth,indexWidth);bounds(values,vo,n,length,lastLength,columns>1?Math.max(4,width):width);
    const iv=new DataView(indices.bytes.buffer,indices.bytes.byteOffset,indices.bytes.length),vv=new DataView(values.bytes.buffer,values.bytes.byteOffset,values.bytes.length);let previous=-1;
    for(let i=0;i<n;i++){const at=iv[indexMethod](io+i*indexWidth,true);if(at<=previous||at>=count)throw new Error('glTF sparse indices must be ordered, unique and in range');previous=at;}
    sparseLayout={iv,vv,indexMethod,indexWidth,io,vo,n};
  }
  // Validate every supplied float before allocating the dense representation.
  // Integer component readers cannot produce nonfinite values; their byte bounds
  // and sparse destinations are already checked above.
  if(accessor.componentType===5126){
    if(base)for(let i=0;i<count;i++)readElement(base.bytes,base.offset+i*base.step);
    if(sparseLayout)for(let i=0;i<sparseLayout.n;i++)readElement(sparseLayout.vv,sparseLayout.vo+i*length);
  }
  const data=new Float64Array(count*size);
  if(base)for(let i=0;i<count;i++)readElement(base.bytes,base.offset+i*base.step,data,i*size);
  if(sparseLayout){const {iv,vv,indexMethod,indexWidth,io,vo,n}=sparseLayout;for(let i=0;i<n;i++){const at=iv[indexMethod](io+i*indexWidth,true);readElement(vv,vo+i*length,data,at*size);}}
  return {data,count,size,type:accessor.type,componentType:accessor.componentType,normalized};
}
