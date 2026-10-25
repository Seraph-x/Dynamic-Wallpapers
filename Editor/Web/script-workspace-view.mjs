import { SCENE_SCRIPT_PROPERTIES,inspectSceneScript,listSceneScripts } from './script-source.mjs';

export function scriptTargets(scene,layerId) {
  const layer=scene.objects?.find(layer=>layer.id===layerId);
  if(!layer)return [];
  const targets=[...SCENE_SCRIPT_PROPERTIES,...(Object.hasOwn(layer,'text')?['text']:[]),...(Array.isArray(layer.effects)?layer.effects.map((_,index)=>`effects[${index}].visible`):[])];
  const records=targets.map(target=>{const selection={layerId,target},state=inspectSceneScript(scene,selection);return {key:target,label:target,selection,state,source:typeof state.source==='string'?state.source:Object.hasOwn(state,'source')?JSON.stringify(state.source,null,2):''};});
  for(const record of listSceneScripts(scene).filter(record=>record.layerId===layerId&&!record.registered)) {
    records.push({key:'metadata:'+JSON.stringify(record.path),label:record.path.join('.'),state:{editable:false,kind:'unsupported',reason:record.reason},source:typeof record.source==='string'?record.source:JSON.stringify(record.source,null,2)});
  }
  return records;
}

// Textarea exposes LF text. Keep a consistently CRLF source's original style;
// mixed imported endings are untouched until input, then use the displayed LF.
export function scriptInputSource(value,original) {
  return original.includes('\r\n')&&!/(?<!\r)\n/.test(original)?value.replace(/\r?\n/g,'\r\n'):value;
}

export function initializeScriptView(t) {
  const panel=document.getElementById('script-panel');
  panel.innerHTML=`<label for="script-target" data-script-text="scriptTarget"></label><select id="script-target"></select>
    <p id="script-note" class="script-note" data-script-text="scriptDraftNote"></p>
    <label for="script-source" data-script-text="scriptSource"></label>
    <textarea id="script-source" wrap="off" spellcheck="false" autocomplete="off" autocapitalize="off" aria-describedby="script-note script-diagnostics"></textarea>
    <div class="script-actions"><button id="script-check" type="button" data-script-text="scriptCheck"></button><button id="script-apply" type="button" class="primary-button" data-script-text="scriptApply"></button><button id="script-revert" type="button" data-script-text="scriptRevert"></button><button id="script-remove" type="button" data-script-text="scriptRemove"></button></div>
    <p id="script-state" class="script-note"></p><pre id="script-diagnostics" class="script-diagnostics" aria-live="polite"></pre>`;
  for(const node of panel.querySelectorAll('[data-script-text]'))node.textContent=t[node.dataset.scriptText];
  const target=document.getElementById('script-target'),input=document.getElementById('script-source'),diagnostics=document.getElementById('script-diagnostics');
  return {panel,target,input,
    targets(records,key){target.replaceChildren(...records.map(record=>{const option=document.createElement('option');option.value=record.key;option.textContent=record.label+(record.state.editable?'':` · ${t.scriptReadOnly}`);return option;}));target.value=key??'';},
    render({source='',state,dirty=false,locked=false,failure,diagnostics:issues=[]}) {
      const display=source.replace(/\r\n?/g,'\n');if(input.value!==display)input.value=source;
      input.readOnly=locked||!state?.editable;target.disabled=locked||!target.options.length;
      input.setAttribute('aria-invalid',String(Boolean(failure)));
      for(const name of ['check','apply','remove'])document.getElementById('script-'+name).disabled=locked||!state?.editable||(name==='remove'&&state.kind!=='script'&&!dirty);
      document.getElementById('script-revert').disabled=locked||(!dirty&&!failure);
      const status=dirty?t.scriptPending:state?.editable?t.scriptCommitted:t.scriptReadOnly;
      if(document.getElementById('script-state').textContent!==status)document.getElementById('script-state').textContent=status;
      const message=failure?`${failure.line?`${t.scriptLine} ${failure.line}: `:''}${failure.message}`:!state?.editable?state?.reason??t.scriptChooseLayer:issues.map(issue=>`${issue.line?`${t.scriptLine} ${issue.line}: `:''}${issue.message}`).join('\n');
      if(diagnostics.textContent!==message)diagnostics.textContent=message;
    },
  };
}
