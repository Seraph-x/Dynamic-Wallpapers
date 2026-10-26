import { CodeEditor } from './code-editor.mjs';
import { lifecycleTemplates } from './script-language.mjs';

export function initializeScriptView(t,{onError,onResolved}) {
  const panel=document.getElementById('script-panel');
  panel.innerHTML=`<label for="script-target" data-script-text="scriptTarget"></label><select id="script-target"></select>
    <p id="script-note" class="script-note" data-script-text="scriptDraftNote"></p>
    <p id="script-source-label" class="script-source-label" data-script-text="scriptSource"></p><div id="script-source"></div>
    <div class="script-actions"><button id="script-check" type="button" data-script-text="scriptCheck"></button><button id="script-apply" type="button" class="primary-button" data-script-text="scriptApply"></button><button id="script-revert" type="button" data-script-text="scriptRevert"></button><button id="script-remove" type="button" data-script-text="scriptRemove"></button></div>
    <p id="script-runtime-location" class="script-note" role="status" hidden></p><p id="script-state" class="script-note"></p><pre id="script-diagnostics" class="script-diagnostics" aria-live="polite"></pre>
    <div class="script-actions"><button id="script-complete" type="button" data-script-text="codeComplete"></button><button id="script-find" type="button" data-script-text="codeFind"></button></div>
    <label for="script-template" data-script-text="codeTemplate"></label><div class="script-template-controls"><select id="script-template"></select><button id="script-use-template" type="button" data-script-text="codeUseTemplate"></button></div>
    <p class="script-note" data-script-text="codeTemplateNote"></p><p class="script-note" data-script-text="codeHostNote"></p>`;
  const dialog=document.createElement('dialog');dialog.id='script-template-confirm';dialog.setAttribute('aria-labelledby','script-template-confirm-title');
  dialog.innerHTML='<h3 id="script-template-confirm-title" data-script-text="codeReplaceTitle"></h3><p data-script-text="codeReplaceDetail"></p><div class="script-actions"><button id="script-template-cancel" type="button" data-script-text="codeCancel"></button><button id="script-template-replace" type="button" class="primary-button" data-script-text="codeReplace"></button></div>';
  document.body.append(dialog);
  for(const root of [panel,dialog])for(const node of root.querySelectorAll('[data-script-text]'))node.textContent=t[node.dataset.scriptText];
  const $=id=>document.getElementById(id),target=$('script-target'),diagnostics=$('script-diagnostics');
  const code=new CodeEditor($('script-source'),{t,onInput:()=>{}});
  let locked=true,editable=false,templateTarget,templates=[],pendingTemplate,templateBarrier;
  const run=operation=>{try{operation();}catch(error){onError(error);}};
  $('script-complete').addEventListener('click',()=>run(()=>code.complete()));
  $('script-find').addEventListener('click',()=>run(()=>{if(locked)throw new Error(t.codeReadOnly);code.find();}));
  const resolveTemplate=()=>{const previous=templateBarrier;pendingTemplate=undefined;templateBarrier=undefined;if(previous)onResolved(previous);};
  const closeTemplate=()=>{dialog.close();resolveTemplate();};
  const replace=()=>{if(locked||!editable)throw new Error(t.codeReadOnly);code.replaceDraft(pendingTemplate.source);closeTemplate();};
  $('script-use-template').addEventListener('click',()=>run(()=>{
    if(locked||!editable)throw new Error(t.codeReadOnly);
    pendingTemplate=templates.find(template=>template.id===$('script-template').value);
    if(!pendingTemplate?.available)throw new Error(t.codeUnavailable[pendingTemplate?.reason]??t.codeReadOnly);
    if(code.text.length){templateBarrier=new Error(t.codeFinishTemplate);dialog.showModal();}else replace();
  }));
  $('script-template-replace').addEventListener('click',()=>run(replace));
  $('script-template-cancel').addEventListener('click',()=>{if(!locked)closeTemplate();});
  dialog.addEventListener('cancel',event=>{if(locked)event.preventDefault();else resolveTemplate();});
  dialog.addEventListener('close',resolveTemplate);
  return {panel,target,onInput:callback=>code.onInput(callback),
    targets(records,key){target.replaceChildren(...records.map(record=>{const option=document.createElement('option');option.value=record.key;option.textContent=record.label+(record.state.editable?'':` · ${t.scriptReadOnly}`);return option;}));target.value=key??'';},
    render({source='',state,dirty=false,locked:blocked=false,failure,diagnostics:issues=[],context,key,target:sourceTarget}) {
      locked=blocked;editable=Boolean(state?.editable);
      $('script-runtime-location').hidden=true;
      code.setSource(source,context,key,sourceTarget);code.setAccess(editable&&!locked,Boolean(failure));
      target.disabled=locked||!target.options.length;
      for(const name of ['check','apply','remove'])$('script-'+name).disabled=locked||!editable||(name==='remove'&&state.kind!=='script'&&!dirty);
      $('script-revert').disabled=locked||(!dirty&&!failure);
      $('script-complete').disabled=locked||!editable;$('script-find').disabled=locked;
      $('script-template').disabled=locked||!editable;$('script-use-template').disabled=locked||!editable;
      if(templateTarget!==sourceTarget){
        templateTarget=sourceTarget;templates=lifecycleTemplates(sourceTarget);
        $('script-template').replaceChildren(...templates.map(template=>{const option=document.createElement('option');option.value=template.id;option.disabled=!template.available;option.textContent=t.codeTemplateNames[template.id]+(template.reason?` · ${t.codeUnavailable[template.reason]}`:'');return option;}));
      }
      const status=dirty?t.scriptPending:editable?t.scriptCommitted:t.scriptReadOnly;
      if($('script-state').textContent!==status)$('script-state').textContent=status;
      const message=failure?`${failure.line?`${t.scriptLine} ${failure.line}: `:''}${failure.message}`:!editable?state?.reason??t.scriptChooseLayer:issues.map(issue=>`${issue.line?`${t.scriptLine} ${issue.line}: `:''}${issue.message}`).join('\n');
      if(diagnostics.textContent!==message)diagnostics.textContent=message;
    },
    get pending(){return dialog.open;},
    reveal:location=>{const note=$('script-runtime-location');note.hidden=false;note.textContent=location.available?`${t.lineReported} ${location.line}`:t[{missing:'lineMissing',outside:'lineOutside',transformed:'lineTransformed'}[location.reason]];code.reveal(location);},
    assertSettled(){if(dialog.open)throw templateBarrier;},
    destroy(){code.destroy();dialog.remove();},
  };
}
