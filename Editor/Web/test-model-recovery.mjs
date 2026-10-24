import assert from 'node:assert/strict';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';

export async function testModelRecovery(page,command,path,bytes) {
  let failed=false;
  const route=async route=>{
    const request=route.request(),event=request.method()==='POST'?request.postDataJSON():undefined;
    if(!failed&&event?.type==='resource'&&event.action==='read'){
      failed=true;await route.fulfill({status:503,body:'Injected read failure'});
    }else await route.continue();
  };
  await page.route('**/__editor/event',route);
  await page.locator('#model-workspace').click();await page.locator('#model-empty').filter({hasText:/503/}).waitFor();
  await page.unroute('**/__editor/event',route);assert(failed,'Read failure was not actually injected');
  await page.locator('#properties-workspace').click();assert.equal(await page.locator('#property-panel').isVisible(),true);
  await page.locator('#model-workspace').click();await page.locator('#model-bones button').nth(2).waitFor();
  const saved=(await command({type:'snapshot'})).document;
  const doc=readMdlDoc(bytes);doc.sections.find(s=>s.type==='MDLS').bones[1].parent=2;
  // The engine can display this forward-parent source, but authoring requires
  // the verified parent-before-child contract. Do not trap the user in Model.
  await command({type:'replace-resource',path,data:Buffer.from(writeMdlDoc(doc)).toString('base64')});
  await page.locator('#model-empty').filter({hasText:/Unsupported source skeleton hierarchy/}).waitFor();
  await page.locator('#properties-workspace').click();assert.equal(await page.locator('#property-panel').isVisible(),true);
  await page.locator('#model-workspace').click();await page.locator('#model-empty').filter({hasText:/Unsupported source skeleton hierarchy/}).waitFor();
  await command({type:'undo'});await page.locator('#model-bones button').nth(2).waitFor();
  assert.deepEqual((await command({type:'snapshot'})).document,saved);
  await page.locator('#properties-workspace').click();
  console.log('Model recovery: failed native-resource read and unsupported source remain visible, allow leaving and recover without content loss');
}
