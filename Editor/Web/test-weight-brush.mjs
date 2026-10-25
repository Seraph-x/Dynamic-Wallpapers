import assert from 'node:assert/strict';
import { testBrushRecovery } from './test-brush-recovery.mjs';
import { testBrushPending } from './test-brush-pending.mjs';
import { readFile,writeFile,mkdir } from 'node:fs/promises';
import path from 'node:path';
import { inspectModel } from './model.mjs';

export async function testWeightBrush({page,command,configuration,resources,blobRoot,artifactRoot,mdlPath,redBounds}) {
  await page.locator('#layers button[data-layer-id="1"]').click();await command({type:'snapshot'});await page.locator('#model-workspace').click();
  await page.locator('#model-bones button[data-bone="1"]').click();await command({type:'snapshot'});
  await page.locator('#model-map-tool').selectOption('paint');
  await page.locator('#model-brush-radius').fill('8');await page.locator('#model-brush-target').fill('1');await page.locator('#model-brush-strength').fill('1');
  const before=(await command({type:'snapshot'})).document,bounds=await redBounds();
  const map=page.locator('#model-weight-map');
  // The 80x40 fixture projects into the 320x180 map with scale 3.7 and 12/16 margins.
  const down=async([x,y]=[12,16])=>{await map.scrollIntoViewIfNeeded();const box=await map.boundingBox();const point={x:box.x+x/320*box.width,y:box.y+y/180*box.height};await page.mouse.move(point.x,point.y);await page.mouse.down();return point;};
  await down();await assert.rejects(command({type:'snapshot'}),/Finish or cancel the weight brush/);await page.keyboard.press('Escape');await page.mouse.up();
  assert.deepEqual((await command({type:'snapshot'})).document,before,'Cancelled stroke changed content');
  await down();await map.dispatchEvent('pointercancel',{pointerId:1});await page.mouse.up();assert.deepEqual((await command({type:'snapshot'})).document,before);
  await testBrushRecovery({page,command,down,before});
  await testBrushPending({page,command,down,before,blobRoot,mdlPath});
  const start=await down();await page.mouse.move(start.x+12,start.y,{steps:3});await page.mouse.up();const painted=(await command({type:'snapshot'})).document;
  const info=inspectModel(new Uint8Array(await readFile(path.join(blobRoot,painted.resourceOverrides[mdlPath]))));
  const weights=info.meshes[0].weights,joints=info.meshes[0].joints;
  const selectedWeight=Array.from({length:4},(_,i)=>joints[i]===1?weights[i]:0).reduce((a,b)=>a+b,0);
  assert(selectedWeight>.999,'The pointer stroke did not reach the target vertex');assert.equal(info.meshes[0].joints[4],0);
  const changed=await redBounds();assert(bounds.min-changed.min>=5*bounds.scale&&bounds.min-changed.min<=11*bounds.scale,'Brush did not create known fixed-corner deformation');
  await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,before);await command({type:'redo'});assert.deepEqual((await command({type:'snapshot'})).document,painted);
  await command({type:'mark-saved',document:painted});await writeFile(path.join(artifactRoot,'brush-workspace.json'),JSON.stringify(painted));
  configuration.document=JSON.parse(await readFile(path.join(artifactRoot,'brush-workspace.json'),'utf8'));
  const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await command({type:'seek',time:.5});
  assert.equal((await redBounds()).min,changed.min,'Saved brush deformation changed after reload');
  const all=[...new Set([...resources.keys(),...Object.keys(painted.resourceOverrides)])],exported=await command({type:'export-pkg',paths:all});
  for(const form of ['Loose','Package']){
    const dir=path.join(artifactRoot,'Brush'+form);await mkdir(dir,{recursive:true});await writeFile(path.join(dir,'project.json'),JSON.stringify({...painted.project,file:form==='Package'?'scene.pkg':'scene.json'}));
    if(form==='Package')await writeFile(path.join(dir,'scene.pkg'),Buffer.from(exported.pkg,'base64'));
    else{await writeFile(path.join(dir,'scene.json'),JSON.stringify(painted.scene));for(const name of all){const version=painted.resourceOverrides[name],target=path.join(dir,name);await mkdir(path.dirname(target),{recursive:true});await writeFile(target,version?await readFile(path.join(blobRoot,version)):resources.get(name));}}
  }
  console.log('Weight brush: actual pointer, cancel/barrier, one-step undo/redo, known deformation, saved reload and loose/PKG exports passed');
}
