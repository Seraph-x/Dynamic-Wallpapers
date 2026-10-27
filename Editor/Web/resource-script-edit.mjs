import { checkSceneScript } from '../Sources/EditorApp/Resources/EditorWeb/script-api.mjs';
import { patchResourceScript } from '../../Resources/SceneScript/resource-contract.mjs';
import { resourceScriptDiscovery } from './resource-scripts.mjs';
import { resourceDigest, resourceOverride, equivalentSnapshot, freezeData } from './resource-script-common.mjs';

const captures=new WeakMap(),proposals=new WeakMap();
const equalBytes=(left,right)=>left.length===right.length&&left.every((value,index)=>value===right[index]);

function assertCurrent(captured) {
  const {editor,document,snapshot}=captured;
  if(typeof editor.closed!=='boolean'||typeof editor.frozen!=='boolean')throw new Error('Editor resource lifetime state is unavailable');
  if(editor.closed)throw new Error('Editor resource session is closed');
  if(editor.frozen)throw new Error('Editor is frozen');
  if(editor.document!==document||!equivalentSnapshot(document.snapshot(),snapshot))throw new Error('Resource script document changed; the capture is stale');
}

async function currentBytes(captured) {
  assertCurrent(captured);
  const input=await captured.editor.readResource(captured.path);
  assertCurrent(captured);
  if(!(input instanceof Uint8Array))throw new Error('Resource script bytes are unavailable');
  const bytes=new Uint8Array(input),digest=await resourceDigest(bytes);
  assertCurrent(captured);
  if(digest!==captured.digest)throw new Error('Resource script bytes changed; the capture is stale');
  return bytes;
}

/** Discovery records are authentic and snapshot-bound; source/bytes stay private and owned. */
export async function captureResourceScript(editor,record) {
  const discovery=resourceScriptDiscovery(record);
  if(!record.registered||!record.editable)throw new Error(record.reason??'Resource script source is read-only');
  if(!editor?.document||typeof editor.document.validateResource!=='function'||typeof editor.readResource!=='function'||typeof editor.stageResource!=='function'||typeof editor.change!=='function')throw new TypeError('Expected an Editor resource transaction owner');
  if(discovery.owner&&editor.document!==discovery.owner)throw new Error('Resource script discovery owner changed; the record is stale');
  const captured={...discovery,editor,document:editor.document,snapshot:structuredClone(discovery.snapshot)};
  assertCurrent(captured);
  captured.document.validateResource(captured.path,captured.digest);
  captured.bytes=await currentBytes(captured);
  const capture=freezeData({path:captured.path,anchor:[...captured.anchor],kind:captured.kind,
    source:record.source??'',hasScript:record.hasScript,valueKind:record.valueKind,resourceDigest:captured.digest});
  captures.set(capture,captured);
  return capture;
}

/** The actual pinned checker constructs a function but never invokes source. No bytes are staged. */
export function prepareResourceScript(capture,edit) {
  const captured=captures.get(capture);
  if(!captured)throw new Error('Resource script capture is forged or unavailable');
  assertCurrent(captured);
  const request=structuredClone(edit);
  if(!request||Object.keys(request).some(key=>!['type','source'].includes(key)))throw new Error('Invalid resource script edit fields');
  const bytes=patchResourceScript({...captured,...request});
  const check=request.type==='set'?checkSceneScript(request.source):null;
  if(check&&!check.ok)throw Object.assign(new Error(check.message),{name:'ResourceScriptSyntaxError',path:captured.path,anchor:[...captured.anchor],line:check.line,check:freezeData(structuredClone(check))});
  const diagnostics=check?.noEntry?[{level:'warning',code:'NO_ENTRY',line:null,message:'The native checker found no recognized entry or engine clock use; compilation does not prove runtime execution.'}]:[];
  const proposal=freezeData({path:captured.path,anchor:[...captured.anchor],type:request.type,
    check:check?structuredClone(check):null,diagnostics});
  proposals.set(proposal,{captured,bytes:new Uint8Array(bytes),check:proposal.check,diagnostics:proposal.diagnostics});
  return proposal;
}

async function applyPrepared(prepared,proposal) {
  const {captured,bytes,check,diagnostics}=prepared;
  const {editor}=captured;
  assertCurrent(captured);
  await currentBytes(captured);
  if(equalBytes(bytes,captured.bytes)){
    proposals.delete(proposal);
    return {changed:false,version:resourceOverride(captured.snapshot,captured.path)??null,check,diagnostics};
  }
  const expected=await resourceDigest(bytes);
  assertCurrent(captured);
  captured.document.validateResource(captured.path,expected);
  const version=await editor.stageResource(new Uint8Array(bytes));
  assertCurrent(captured);
  if(version!==expected)throw new Error('Staged resource script hash is corrupt');
  await currentBytes(captured);
  let applied=false;
  await editor.change(document=>{
    assertCurrent(captured);
    if(document!==captured.document)throw new Error('Resource script document changed before mutation');
    document.validateResource(captured.path,version);
    document.transaction(draft=>draft.resource(captured.path,version));
    applied=true;proposals.delete(proposal);
  });
  if(!applied)throw new Error('Editor resource change did not apply its transaction');
  return {changed:true,version,check,diagnostics};
}

/** A native session must remain held by the owning Editor throughout this asynchronous operation. */
export async function commitResourceScript(editor,proposal) {
  const prepared=proposals.get(proposal);
  if(!prepared)throw new Error('Resource script proposal is forged or already consumed');
  if(prepared.captured.editor!==editor)throw new Error('Resource script proposal belongs to another Editor');
  if(prepared.inFlight)throw new Error('Resource script proposal is already being committed');
  prepared.inFlight=true;
  try{return await applyPrepared(prepared,proposal);}
  finally{prepared.inFlight=false;}
}
