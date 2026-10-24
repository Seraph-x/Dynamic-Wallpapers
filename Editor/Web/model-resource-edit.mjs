import { safePath } from './document.mjs';

export function modelResourceSource(editor,id) {
  const info=editor.controls?.getModelInfo(id);
  if(!info?.mdlPath)throw new Error('Select a loaded model layer');
  const path=safePath(info.mdlPath);
  return Object.freeze({document:editor.document,id,path,version:editor.document.snapshot().resourceOverrides?.[path]});
}
function assertCurrent(editor,source) {
  if(editor.document!==source.document || editor.controls?.getModelInfo(source.id)?.mdlPath!==source.path ||
    editor.document.snapshot().resourceOverrides?.[source.path]!==source.version)throw new Error('Model document or resource changed; the edit is stale');
}
export async function commitModelResource(editor,source,bytes) {
  assertCurrent(editor,source);
  if(!(bytes instanceof Uint8Array))throw new Error('Expected edited model bytes');
  const version=await editor.stageResource(bytes.slice());
  assertCurrent(editor,source);
  await editor.change(doc=>{assertCurrent(editor,source);doc.resource(source.path,version);});
}
