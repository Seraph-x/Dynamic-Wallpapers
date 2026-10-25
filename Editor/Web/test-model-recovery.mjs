import assert from 'node:assert/strict';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';

export async function testModelRecovery(page,command,path,bytes) {
  let failed=false;
  const route=async route=>{
    const request=route.request(),event=request.method()==='POST'?request.postDataJSON():undefined;
    if(!failed&&event?.type==='resource'&&event.action==='read'){
      console.log('Model recovery step=injected-read-503');failed=true;await route.fulfill({status:503,body:'Injected read failure'});
    }else await route.continue();
  };
  console.log('Model recovery step=route-read-failure');
  await page.route('**/__editor/event',route);
  console.log('Model recovery step=activate-after-read-injection');
  await page.locator('#model-workspace').click();
  console.log('Model recovery step=await-visible-503');
  await page.locator('#model-empty').filter({hasText:/503/}).waitFor();
  console.log('Model recovery step=503-visible');
  console.log('Model recovery step=remove-read-injection');
  await page.unroute('**/__editor/event',route);assert(failed,'Read failure was not actually injected');
  await page.locator('#properties-workspace').click();assert.equal(await page.locator('#property-panel').isVisible(),true);
  await page.locator('#model-workspace').click();await page.locator('#model-bones button').nth(2).waitFor();
  console.log('Model recovery step=restored-bones');
  const saved=(await command({type:'snapshot'})).document;
  const doc=readMdlDoc(bytes);doc.sections.find(s=>s.type==='MDLS').bones[1].parent=2;
  // The engine can display this forward-parent source, but authoring requires
  // the verified parent-before-child contract. Do not trap the user in Model.
  console.log('Model recovery step=replace-forward-parent');
  await command({type:'replace-resource',path,data:Buffer.from(writeMdlDoc(doc)).toString('base64')});
  await page.locator('#model-empty').filter({hasText:/Unsupported source skeleton hierarchy/}).waitFor();
  await page.locator('#properties-workspace').click();assert.equal(await page.locator('#property-panel').isVisible(),true);
  await page.locator('#model-workspace').click();await page.locator('#model-empty').filter({hasText:/Unsupported source skeleton hierarchy/}).waitFor();
  console.log('Model recovery step=undo-forward-parent');
  await command({type:'undo'});await page.locator('#model-bones button').nth(2).waitFor();
  assert.deepEqual((await command({type:'snapshot'})).document,saved);
  await page.locator('#properties-workspace').click();
  console.log('Model recovery: failed native-resource read and unsupported source remain visible, allow leaving and recover without content loss');
}
