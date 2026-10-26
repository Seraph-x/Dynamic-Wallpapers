import { CodeEditor } from './code-editor.mjs';
import { scriptLineSelection } from './script-navigation.mjs';
export function createCapturedScriptView(t) {
 const dialog=document.createElement('dialog');dialog.id='script-captured-dialog';dialog.setAttribute('aria-labelledby','script-captured-title');
 dialog.innerHTML='<h2 id="script-captured-title"></h2><p id="script-captured-reason"></p><p id="script-captured-note"></p><p id="script-captured-label"></p><div id="script-captured-source"></div><p id="script-captured-location" role="status"></p><div class="script-actions"><button id="script-captured-find" type="button"></button><button id="script-captured-close" type="button" autofocus></button></div>';
 document.body.append(dialog);const $=id=>dialog.querySelector('#script-captured-'+id);
 $('title').textContent=t.capturedTitle;$('note').textContent=t.capturedNote;$('label').textContent=t.capturedSource;$('find').textContent=t.capturedFind;$('close').textContent=t.capturedClose;
 const code=new CodeEditor($('source'),{t,onInput:()=>{throw new Error('Captured source is read-only');},labelID:'script-captured-label',descriptionID:'script-captured-note script-captured-location'});
 $('close').addEventListener('click',()=>dialog.close());$('find').addEventListener('click',()=>code.find());
 return {show({link,reason},{preserveFocus=false}={}){
   $('reason').textContent=t['nav'+reason[0].toUpperCase()+reason.slice(1)];
   const location=scriptLineSelection(link.source,link.line);
   $('location').textContent=location.available?`${t.lineReported} ${link.line}`:t[{missing:'lineMissing',outside:'lineOutside',transformed:'lineTransformed'}[location.reason]];
   code.setSource(link.source,link,JSON.stringify(link.path),undefined);code.setAccess(false,false);
   if(!dialog.open){if(preserveFocus)dialog.setAttribute('open','');else dialog.showModal();}code.reveal(location,{focus:!preserveFocus});
 },close(){dialog.close();},destroy(){code.destroy();dialog.remove();}};
}
