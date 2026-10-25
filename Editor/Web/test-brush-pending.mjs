import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { inspectModel } from './model.mjs';

export async function testBrushPending({page,command,down,before,blobRoot,mdlPath}) {
  await page.locator('#model-brush-strength').fill('0');await down();await assert.rejects(command({type:'snapshot'}),/Finish or cancel the weight brush/);
  await page.mouse.up();assert.deepEqual((await command({type:'snapshot'})).document,before,'No-op completion retained a stale brush barrier');
  await page.locator('#model-brush-strength').fill('1');
  let resume,reached,blocked=false;
  const gate=new Promise(resolve=>{resume=resolve;}),started=new Promise(resolve=>{reached=resolve;});
  const delay=async route=>{const e=route.request().method()==='POST'?route.request().postDataJSON():undefined;
    if(e?.type==='resource'&&e.action==='stage'&&!blocked){blocked=true;reached();await gate;}await route.continue();};
  await page.route('**/__editor/event',delay);
  try{
    await page.locator('#model-bone-name').fill('Pending Fixed');await down();await started;await page.mouse.up();
    const freezing=command({type:'freeze'});await page.waitForFunction(()=>document.body.inert);resume();const frozen=(await freezing).document;
    const info=inspectModel(new Uint8Array(await readFile(path.join(blobRoot,frozen.resourceOverrides[mdlPath]))));assert.equal(info.bones[1].name,'Pending Fixed');
    const selected=Array.from({length:4},(_,i)=>info.meshes[0].joints[i]===1?info.meshes[0].weights[i]:0).reduce((a,b)=>a+b,0);
    assert(selected>.999,'Freeze discarded a completed stroke while preparation was pending');
    await command({type:'thaw'});await command({type:'undo'});const renamed=(await command({type:'snapshot'})).document;
    assert.notDeepEqual(renamed,before,'Brush undo removed the independent prior bone draft');await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,before);
  }finally{resume();await page.unroute('**/__editor/event',delay);}
}
