import assert from 'node:assert/strict';

export async function testImagePuppetLayout(page,command,configuration,original) {
  configuration.document=original;
  for(const language of ['en','zh-Hans','ja','fr','es']){
    configuration.language=language;
    const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');
    await page.reload();await ready;await command({type:'thaw'});
    await page.locator('#layers button[data-layer-id="1"]').click();await command({type:'snapshot'});await page.locator('#model-workspace').click();
    await page.setViewportSize({width:850,height:540});await page.locator('#timeline-toggle').click();
    for(const theme of ['light','dark']){
      await page.locator('#theme').selectOption(theme);await page.locator('#model-image-create').click();
      await page.locator('#model-image-root').waitFor();
      const layout=await page.evaluate(()=>{
        const d=document.querySelector('#model-image-dialog'),box=d.getBoundingClientRect();
        return {overflow:document.documentElement.scrollWidth>innerWidth,inside:box.left>=0&&box.right<=innerWidth&&box.top>=0&&box.bottom<=innerHeight,
          contentFits:d.scrollWidth<=d.clientWidth,focused:document.activeElement.id,labels:[...d.querySelectorAll('label')].map(l=>({text:l.textContent,associated:Boolean(l.control)}))};
      });
      assert.equal(layout.overflow,false,`${language}/${theme}: page overflow`);assert.equal(layout.inside,true,`${language}/${theme}: dialog outside viewport`);
      assert.equal(layout.contentFits,true,`${language}/${theme}: horizontal dialog overflow`);assert.equal(layout.focused,'model-image-root');
      assert(layout.labels.every(l=>l.text&&!l.text.includes('undefined')&&l.associated));
      await page.keyboard.press('Tab');assert(await page.evaluate(()=>document.querySelector('#model-image-dialog').contains(document.activeElement)),'Modal focus escaped');
      await page.keyboard.press('Escape');await page.locator('#model-image-dialog').waitFor({state:'hidden'});
      assert.deepEqual((await command({type:'snapshot'})).document,original,'Layout, theme or cancellation changed content');
    }
  }
  console.log('Image mesh dialog: five languages, both themes, 850x540 with Timeline, associated labels, modal focus and Escape passed');
}
