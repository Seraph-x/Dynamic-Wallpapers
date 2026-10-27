import { resourceScriptPath } from '../../Resources/SceneScript/resource-contract.mjs';
import { parseResourceJSON, jsonNodeAt } from '../../Resources/SceneScript/json-spans.mjs';
import { readMdlDoc } from './vendor/mdl-codec.mjs';

const canonical=path=>path.normalize('NFC').toLowerCase();
export function resourceInventory(paths,snapshot) {
  if(!Array.isArray(paths))throw new TypeError('Resource path inventory required');
  const entries=new Map(),directories=new Map();
  const add=path=>{
    resourceScriptPath(path);
    const key=canonical(path);
    if(entries.has(key))throw new Error(`Duplicate or ambiguous resource path: ${path}`);
    entries.set(key,path);
    const parts=path.split('/');
    for(let end=1;end<parts.length;end++){
      const parent=parts.slice(0,end).join('/'),key=canonical(parent),previous=directories.get(key);
      if(previous!==undefined&&previous!==parent)throw new Error(`Ambiguous resource directory: ${parent}`);
      directories.set(key,parent);
    }
  };
  for(const path of paths)add(path);
  for(const [path,version] of Object.entries(snapshot.resourceOverrides??{})){
    if(typeof version!=='string'||!/^[a-f0-9]{64}$/.test(version))throw new Error('Invalid resource override hash');
    if(!entries.has(canonical(path)))add(path);
    else if(entries.get(canonical(path))!==path)throw new Error(`Ambiguous resource override path: ${path}`);
  }
  if([...entries.keys()].some(key=>directories.has(key)))throw new Error('Resource file/directory collision');
  return new Set(entries.values());
}

export function sceneResourceRoots(snapshot) {
  if(!snapshot?.scene||typeof snapshot.scene!=='object'||!Array.isArray(snapshot.scene.objects??[]))throw new Error('Invalid resource discovery scene');
  const roots=[];
  for(const [layerIndex,layer] of (snapshot.scene.objects??[]).entries()){
    if(!layer||typeof layer!=='object'||Array.isArray(layer))continue;
    const context={layerId:typeof layer.id==='number'&&Number.isFinite(layer.id)?layer.id:null,layerIndex};
    if(typeof layer.image==='string')roots.push({path:layer.image,kind:/\.mdl$/i.test(layer.image)?'mdl':'model',consumer:{...context,kind:'image'}});
    if(typeof layer.model==='string')roots.push({path:layer.model,kind:'mdl',consumer:{...context,kind:'mesh'}});
    if(typeof layer.particle==='string')roots.push({path:layer.particle,kind:'particle',consumer:{...context,kind:'particle'}});
    if(Array.isArray(layer.effects))for(const [effect,entry] of layer.effects.entries()){
      if(entry&&typeof entry.file==='string')roots.push({path:entry.file,kind:'effect',consumer:{...context,kind:'effect',effect}});
    }
  }
  return roots;
}

function stringAt(document,path){const node=jsonNodeAt(document,path);return node?.kind==='string'?node.value:undefined;}
export function resourceEdges(bytes,kind) {
  if(kind==='mdl'){
    const mdl=readMdlDoc(new Uint8Array(bytes));
    if(mdl.raw||!Array.isArray(mdl.meshes))throw new Error('Unsupported MDL resource material table');
    return mdl.meshes.flatMap((mesh,meshIndex)=>(mesh.materials??[]).map((path,skin)=>({path,kind:'material',context:{mesh:meshIndex,skin,kind:'mesh',
      ...(skin ? {consumed:false,unavailableReason:'The pinned renderer consumes only the first MDL skin material'} : {})}})));
  }
  const document=parseResourceJSON(bytes,{mode:kind==='particle'||kind==='model'?'json':'jsonc'}),edges=[];
  if(kind==='model'||kind==='particle'){
    const material=stringAt(document,['material']);
    if(material)edges.push({path:material,kind:'material',context:{kind:kind==='particle'?'particle':'image'}});
  }
  if(kind==='effect'){
    const passes=jsonNodeAt(document,['passes']);
    if(passes?.kind==='array')for(let pass=0;pass<passes.items.length;pass++){
      const path=stringAt(document,['passes',pass,'material']);
      if(path)edges.push({path,kind:'material',context:{kind:'effect',pass}});
    }
  }
  if(kind==='particle'){
    const children=jsonNodeAt(document,['children']);
    if(children?.kind==='array')for(let child=0;child<children.items.length;child++){
      const path=stringAt(document,['children',child,'name']);
      if(path)edges.push({path,kind:'particle',context:{kind:'particle',child}});
    }
  }
  return edges;
}

export function materialConsumers(bytes,consumers) {
  const document=parseResourceJSON(bytes,{mode:'jsonc'}),shader=stringAt(document,['passes',0,'shader'])??'';
  return consumers.map(consumer=>consumer.kind==='image'?{...consumer,kind:/^generic|^(sprite|flat)$/i.test(shader)?'tint':'effect',usage:'image-material'}:consumer);
}
