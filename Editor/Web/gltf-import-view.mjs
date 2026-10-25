const node=(tag,properties={},...children)=>{const element=Object.assign(document.createElement(tag),properties);element.append(...children);return element;};
export function initializeGltfImportView(t){
 const dialog=node('dialog',{id:'gltf-dialog',className:'gltf-dialog'}),form=node('form',{id:'gltf-form'}),title=node('h2',{id:'gltf-title',textContent:t.gltfTitle}),note=node('p',{id:'gltf-note',textContent:t.gltfNote});
 dialog.setAttribute('aria-labelledby',title.id);dialog.setAttribute('aria-describedby',note.id);form.append(title,note);
 const fields=node('div',{className:'gltf-options'}),inputs={};
 function field(key,label,element){element.id=`gltf-${key}`;element.name=key;element.setAttribute('aria-describedby','gltf-error');inputs[key]=element;fields.append(node('div',{className:'property-field'},node('label',{htmlFor:element.id,textContent:label}),element));return element;}
 field('name',t.name,node('input',{type:'text',required:true,autofocus:true}));field('scene',t.gltfScene,node('select'));
 field('scale',t.gltfScale,node('input',{type:'number',step:'any',min:'0',required:true,value:'1'}));field('fps',t.gltfFPS,node('input',{type:'number',step:'any',min:'0',max:'240',required:true,value:'30'}));
 field('mode',t.gltfMode,node('select',{},node('option',{value:'loop',textContent:t.gltfLoop}),node('option',{value:'single',textContent:t.gltfSingle})));
 for(const axis of ['x','y','z'])field(axis,`${t.origin} ${axis}`,node('input',{type:'number',step:'any',required:true,value:'0'}));form.append(fields);
 const preview=node('div',{id:'gltf-preview',className:'gltf-preview'}),stats=node('p',{id:'gltf-stats'}),details=node('details',{open:true},node('summary',{textContent:t.gltfApprox})),clips=node('ul',{id:'gltf-clips'}),sources=node('ul',{id:'gltf-sources'});
 details.append(node('p',{textContent:t.gltfSampling}),node('p',{textContent:t.gltfBaking}),clips,node('h3',{textContent:t.gltfArchive}),sources);
 const pbrNote=node('p',{id:'gltf-pbr-note',textContent:t.gltfConsent}),twoSidedNote=node('p',{id:'gltf-two-sided-note',textContent:t.gltfTwoSided});pbrNote.hidden=true;twoSidedNote.hidden=true;details.append(pbrNote,twoSidedNote);
 const consent=node('input',{type:'checkbox',id:'gltf-consent',name:'consent'}),consentLabel=node('label',{className:'gltf-consent',htmlFor:consent.id},consent,node('span',{textContent:t.gltfAccept}));consentLabel.hidden=true;consent.setAttribute('aria-describedby','gltf-pbr-note gltf-two-sided-note');
 const error=node('p',{id:'gltf-error',className:'image-mesh-error'});error.setAttribute('role','alert');error.setAttribute('aria-live','polite');
 form.append(preview,stats,details,consentLabel,error,node('div',{className:'model-actions'},node('button',{type:'button',id:'gltf-update',textContent:t.gltfPreview}),node('button',{type:'submit',id:'gltf-confirm',textContent:t.gltfImport}),node('button',{type:'button',id:'gltf-cancel',textContent:t.cancel})));dialog.append(form);document.body.append(dialog);
 return {dialog,form,preview,inputs,consent,
  show(source,snapshot){inputs.name.value=source.entry.split('/').at(-1).replace(/\.(gltf|glb)$/i,'');inputs.scale.value='1';inputs.fps.value='30';inputs.mode.value='loop';consent.checked=false;
   const scenes=source.json.scenes??[];inputs.scene.replaceChildren(...(scenes.length?scenes:[{}]).map((s,i)=>node('option',{value:String(i),textContent:s.name??`${t.gltfScene} ${i+1}`})));inputs.scene.value=String(source.json.scene??0);
   const projection=snapshot.scene.general?.orthogonalprojection;inputs.x.value=String((projection?.width??0)/2);inputs.y.value=String((projection?.height??0)/2);inputs.z.value='0';error.textContent='';stats.textContent='';clips.replaceChildren();sources.replaceChildren(...source.files.map(f=>node('li',{textContent:`${f.path} · ${f.bytes.length} B` })));dialog.showModal();},
  values(){return {name:inputs.name.value,scene:Number(inputs.scene.value),scale:inputs.scale.valueAsNumber,fps:inputs.fps.valueAsNumber,mode:inputs.mode.value,origin:['x','y','z'].map(k=>inputs[k].valueAsNumber)};},
  ready(candidate){stats.textContent=`${t.gltfStats}: ${candidate.spec.meshes.length} / ${candidate.boneCount} / ${candidate.spec.animations.length}`;clips.replaceChildren(...candidate.animationInfo.map(c=>node('li',{textContent:`${c.name}: ${c.sourceDuration.toFixed(6)} → ${c.encodedDuration.toFixed(6)} s · ${c.frameCount} · ${c.fps} FPS`})));pbrNote.hidden=!candidate.requiresUnlitConsent;twoSidedNote.hidden=!candidate.requiresTwoSidedConsent;consentLabel.hidden=!(candidate.requiresUnlitConsent||candidate.requiresTwoSidedConsent);consent.required=!consentLabel.hidden;},
  error(message){error.textContent=message;},busy(value,locked=false){for(const element of form.querySelectorAll('input,select,button'))element.disabled=value||locked;if(!value&&!locked&&dialog.open&&!form.contains(document.activeElement))inputs.name.focus();},close(){dialog.close();},valid(){return form.reportValidity();}
 };
}
