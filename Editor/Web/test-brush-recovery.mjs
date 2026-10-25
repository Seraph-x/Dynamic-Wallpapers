import assert from 'node:assert/strict';

export async function testBrushRecovery({page,command,down,before}) {
  await page.locator('#model-brush-strength').fill('2');assert.deepEqual((await command({type:'snapshot'})).document,before,'Preview-only brush settings blocked snapshot');await page.locator('#model-brush-strength').fill('1');
  await page.locator('#model-bones button[data-bone="0"]').click();await page.locator('#model-brush-target').fill('0');
  await down([160,2]);await assert.rejects(command({type:'snapshot'}),/Finish or cancel the weight brush/);
  const mapBox=await page.locator('#model-weight-map').boundingBox();await page.mouse.move(mapBox.x+12/320*mapBox.width,mapBox.y+16/180*mapBox.height);
  await page.locator('#diagnostics').filter({hasText:/sole skin influence/}).waitFor();await page.mouse.up();
  assert.deepEqual((await command({type:'snapshot'})).document,before,'A failed preview left its obsolete brush barrier latched');
  await page.locator('#model-weights-revert').click();await page.locator('#model-bones button[data-bone="1"]').click();await page.locator('#model-brush-target').fill('1');
  let failed=false;
  const fail=async route=>{const e=route.request().method()==='POST'?route.request().postDataJSON():undefined;
    if(!failed&&e?.type==='resource'&&e.action==='stage'){failed=true;await route.fulfill({status:503,body:'Injected brush stage failure'});}else await route.continue();};
  await page.route('**/__editor/event',fail);
  try{await down();await page.mouse.up();await page.locator('#diagnostics').filter({hasText:/503/}).waitFor();assert(failed);}
  finally{await page.unroute('**/__editor/event',fail);}
  await page.locator('#model-weights-revert').click();assert.deepEqual((await command({type:'snapshot'})).document,before,'Failed brush staging changed content');
  await page.locator('#model-map-tool').selectOption('select');await page.locator('#model-weight-map').focus();await page.keyboard.press('End');
  assert.equal(await page.locator('#model-vertex').inputValue(),'24');await page.keyboard.press('Home');assert.equal(await page.locator('#model-vertex').inputValue(),'0');
  assert.deepEqual((await command({type:'snapshot'})).document,before,'Selection mode dirtied content');await page.locator('#model-map-tool').selectOption('paint');
  await page.locator('#timeline-toggle').click();await page.locator('#timeline-create').click();const animated=(await command({type:'snapshot'})).document;
  await page.locator('#timeline-key-value').fill('');await down();await assert.rejects(command({type:'snapshot'}),/Finish or cancel the weight brush/);
  await page.keyboard.press('Escape');await page.mouse.up();assert.equal(await page.locator('#timeline-key-value').inputValue(),'');
  await assert.rejects(command({type:'snapshot'}),/Invalid|value|fill/i,'Brush cancellation discarded an unrelated invalid Timeline draft');
  await page.locator('#timeline-revert').click();assert.deepEqual((await command({type:'snapshot'})).document,animated);
  await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,before);await page.locator('#timeline-toggle').click();
  await command({type:'seek',time:.5});
  console.log('Brush recovery: stage failure, keyboard selection, unrelated Timeline draft and cancellation passed');
}
