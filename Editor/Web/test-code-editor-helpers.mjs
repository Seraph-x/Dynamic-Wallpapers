import assert from 'node:assert/strict';

// Read-only inspection uses CodeMirror's public API. All document changes use
// the visible contenteditable and real browser keyboard input.
export const codeContent=page=>page.locator('#script-source .cm-content');
export async function inspectCodeEditor(page) {
  return page.evaluate(async()=>{
    const {EditorView,EditorState}=await import('./code-editor-api.mjs');
    const content=document.querySelector('#script-source .cm-content'),view=EditorView.findFromDOM(content);
    if(!view)throw new Error('The visible source has no real CodeMirror EditorView');
    return {source:view.state.sliceDoc(),readOnly:view.state.facet(EditorState.readOnly),editable:view.state.facet(EditorView.editable),contentEditable:content.getAttribute('contenteditable'),role:content.getAttribute('role'),labelledBy:content.getAttribute('aria-labelledby'),selection:{from:view.state.selection.main.from,to:view.state.selection.main.to}};
  });
}
export async function codeReadOnly(page) {
  const state=await inspectCodeEditor(page);
  return state.readOnly===true&&state.editable===false&&state.contentEditable==='false';
}
export function codeInput(page) {
  return {
    inputValue:async()=>(await inspectCodeEditor(page)).source,
    async fill(source){
      // Playwright polls a synchronous predicate. An async predicate returns a
      // truthy Promise and stops polling even when it later resolves false.
      await page.waitForFunction(()=>{
        const content=document.querySelector('#script-source .cm-content');
        return content?.getAttribute('contenteditable')==='true'&&!document.getElementById('script-target').disabled;
      });
      await codeContent(page).click();await page.keyboard.press('ControlOrMeta+a');
      const before=await inspectCodeEditor(page);
      if(source)await page.keyboard.insertText(source);else await page.keyboard.press('Backspace');
      // CDP input acknowledgement can precede CodeMirror's DOM observer. Read
      // the current public view until that one input has actually settled.
      const api=await page.evaluateHandle(()=>import('./code-editor-api.mjs'));
      try{
        await page.waitForFunction(({api,source})=>{
          const view=api.EditorView.findFromDOM(document.querySelector('#script-source .cm-content'));
          return Boolean(view&&view.state.sliceDoc()===source);
        },{api,source});
      }catch(error){
        console.error('Code input did not settle',{before,after:await inspectCodeEditor(page),dom:await codeContent(page).innerText()});
        throw error;
      }finally{await api.dispose();}
      const after=await inspectCodeEditor(page);
      if(after.source!==source)console.error('Code input failure state',{before,after,active:await page.evaluate(()=>({tag:document.activeElement?.tagName,classes:document.activeElement?.className,inert:document.body.inert,contentEditable:document.querySelector('#script-source .cm-content').getAttribute('contenteditable')}))});
      assert.equal(after.source,source,'Real keyboard input did not reach the CodeMirror document');
    },
    focus:()=>codeContent(page).focus(),
    getAttribute:name=>codeContent(page).getAttribute(name),
    evaluate:callback=>codeContent(page).evaluate(callback),
  };
}
