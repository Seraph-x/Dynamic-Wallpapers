import assert from 'node:assert/strict';

export async function testModelLayout(page,command,configuration,document) {
  const originalViewport=page.viewportSize();
  configuration.document=document;
  for(const language of ['en','zh-Hans','ja','fr','es']){
    configuration.language=language;
    const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');
    await page.reload();await ready;await command({type:'thaw'});await page.getByRole('button',{name:'Rig',exact:true}).click();
    await page.locator('#model-workspace').click();await page.locator('#model-bones button').nth(2).waitFor();
    await page.locator('#model-rest-details summary').click();assert.equal(await page.locator('#model-rest-form input').count(),9);
    assert.equal(await page.locator('#model-rest-tx').isEnabled(),true);
    await page.locator('#model-map-tool').selectOption('paint');assert.equal(await page.locator('#model-brush-parameters').isVisible(),true);
    await page.setViewportSize({width:850,height:540});await page.locator('#timeline-toggle').click();
    const layout=await page.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,
      inspectorOverflow:document.querySelector('.inspector-scroll').scrollWidth>document.querySelector('.inspector-scroll').clientWidth,
      canvas:document.querySelector('.canvas-stage').getBoundingClientRect().height,
      missing:[...document.querySelectorAll('#model-panel label,#model-panel legend,.model-dialog label')].some(e=>!e.textContent||e.textContent.includes('undefined'))}));
    assert.equal(layout.overflow,false,`${language}: model workspace page overflow`);assert.equal(layout.inspectorOverflow,false,`${language}: model inspector overflow`);
    assert.equal(layout.missing,false,`${language}: missing model label`);assert(layout.canvas>80,`${language}: model workspace obscures canvas`);
    await page.locator('#timeline-toggle').click();await page.locator('#theme').selectOption('dark');await page.locator('#theme').selectOption('light');
    await page.locator('#model-map-tool').selectOption('select');
    assert.deepEqual((await command({type:'snapshot'})).document,document,'Model layout/theme/selection dirtied content');
  }
  await page.setViewportSize(originalViewport);await page.locator('#properties-workspace').click();
  console.log('Model layout: brush controls, five languages, both themes and 850x540 with Timeline passed without content edits');
}
