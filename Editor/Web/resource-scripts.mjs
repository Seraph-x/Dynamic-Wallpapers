import { inspectResourceScripts, resourceScriptPath } from '../../Resources/SceneScript/resource-contract.mjs';
import { resourceInventory, sceneResourceRoots, resourceEdges, materialConsumers } from './resource-script-inventory.mjs';
import { resourceDigest, resourceOverride, equivalentSnapshot, freezeData } from './resource-script-common.mjs';

const discoveries=new WeakMap();
const errorRecord=(path,kind,message)=>({path,kind,anchor:[],registered:false,editable:false,reason:message,hasScript:false});

/** Reader must resolve the supplied snapshot; returned records own bytes and never execute source. */
export async function discoverResourceScripts({snapshot,paths,read}) {
  if(typeof read!=='function')throw new TypeError('Resource reader required');
  const owned=structuredClone(snapshot),inventory=resourceInventory(paths,owned),queue=sceneResourceRoots(owned).map(root=>({...root,ancestors:[]}));
  const files=new Map(),nodes=new Map(),failedNodes=new Set(),covered=new Set(),failures=[],unavailable=[],records=[];
  async function load(path){
    if(!files.has(path))files.set(path,(async()=>{
      const input=await read(path);
      if(!(input instanceof Uint8Array))throw new Error(`Resource bytes disappeared: ${path}`);
      const bytes=new Uint8Array(input),digest=await resourceDigest(bytes),version=resourceOverride(owned,path);
      if(version&&version!==digest)throw new Error(`Resource override hash is corrupt: ${path}`);
      return {bytes,digest};
    })());
    return files.get(path);
  }
  const fail=(path,kind,error)=>{
    const message=String(error?.message??error);
    failures.push({path,kind,message});records.push(errorRecord(path,kind,message));
  };
  for(let cursor=0;cursor<queue.length;cursor++){
    const request=queue[cursor],{path,kind,consumer,ancestors}=request;
    try{
      resourceScriptPath(path);
      if(ancestors.includes(path))throw new Error(`Cyclic resource reference: ${[...ancestors,path].join(' -> ')}`);
      if(!inventory.has(path)){
        const message='Resource reference has no owned bytes in the inventory';
        unavailable.push({path,kind,message});records.push(errorRecord(path,kind,message));continue;
      }
      const key=JSON.stringify([path,kind]);
      covered.add(path);
      if(failedNodes.has(key))continue;
      if(!nodes.has(key)){
        try{
          const loaded=await load(path);
          nodes.set(key,{path,kind,...loaded,edges:resourceEdges(loaded.bytes,kind),consumers:[]});
        }catch(error){failedNodes.add(key);throw error;}
      }
      const node=nodes.get(key);
      if(node.consumers.some(previous=>JSON.stringify(previous)===JSON.stringify(consumer)))continue;
      node.consumers.push(structuredClone(consumer));
      for(const edge of node.edges)queue.push({...edge,consumer:{...consumer,...edge.context,via:[...(consumer.via??[]),{path,kind,...edge.context}]},ancestors:[...ancestors,path]});
    }catch(error){fail(path,kind,error);}
  }
  for(const path of inventory){
    if(covered.has(path)||path===owned.entry||path==='project.json')continue;
    if(!/\.(jsonc?|gltf|m?js)$/i.test(path))continue;
    try{
      const loaded=await load(path);
      if(/\.m?js$/i.test(path)){
        const source=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(loaded.bytes);
        records.push({...errorRecord(path,'standalone','The pinned runtime does not load standalone script modules'),source,hasScript:true});
      }else nodes.set(JSON.stringify([path,'unknown']),{path,kind:'unknown',...loaded,consumers:[]});
    }catch(error){fail(path,'unknown',error);}
  }
  for(const node of nodes.values()){
    if(node.kind==='mdl')continue;
    try{
      const kind=['material','particle'].includes(node.kind)?node.kind:'unknown';
      const consumers=kind==='material'?materialConsumers(node.bytes,node.consumers):node.consumers;
      const report=inspectResourceScripts({path:node.path,bytes:node.bytes,kind,consumers});
      for(const message of report.errors)fail(node.path,node.kind,new Error(message));
      for(const record of report.records){
        const output=freezeData({...record,resourceDigest:node.digest,overrideVersion:resourceOverride(owned,node.path),checked:false});
        discoveries.set(output,{snapshot:owned,path:node.path,kind,consumers,bytes:node.bytes,digest:node.digest,anchor:[...record.anchor]});
        records.push(output);
      }
    }catch(error){fail(node.path,node.kind,error);}
  }
  return freezeData({scope:'resource-source-discovery',records,failures,unavailable});
}

/** Bind the dynamic Editor reader to one owner/snapshot before and after every asynchronous read. */
export async function discoverEditorResourceScripts(editor) {
  if(!editor?.document||typeof editor.document.snapshot!=='function'||typeof editor.resourcePaths!=='function'||typeof editor.readResource!=='function'||typeof editor.closed!=='boolean')throw new TypeError('Expected an Editor discovery owner');
  const owner=editor.document,snapshot=owner.snapshot();
  const assertSnapshot=()=>{
    if(editor.closed)throw new Error('Editor resource discovery is closed');
    if(editor.document!==owner||!equivalentSnapshot(owner.snapshot(),snapshot))throw new Error('Resource discovery document changed; the scan is stale');
  };
  assertSnapshot();
  const paths=await editor.resourcePaths();assertSnapshot();
  const report=await discoverResourceScripts({snapshot,paths,read:async path=>{
    assertSnapshot();
    const bytes=await editor.readResource(path);assertSnapshot();return bytes;
  }});
  assertSnapshot();
  for(const record of report.records){const captured=discoveries.get(record);if(captured)captured.owner=owner;}
  return report;
}

/** Opaque-record validation; copies cannot mutate a discovery's retained source. */
export function resourceScriptDiscovery(record) {
  const captured=discoveries.get(record);
  if(!captured)throw new Error('Resource script discovery record is forged or unavailable');
  return {...captured,snapshot:structuredClone(captured.snapshot),consumers:structuredClone(captured.consumers),bytes:new Uint8Array(captured.bytes),anchor:[...captured.anchor]};
}
