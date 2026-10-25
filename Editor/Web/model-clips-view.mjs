const node=(tag,properties={},...children)=>{const e=Object.assign(document.createElement(tag),properties);e.append(...children);return e;};
const $=id=>document.getElementById(id);
function field(parent,id,label,type='text'){
 const input=node(type==='select'?'select':'input',{id,name:id,...(type==='select'?{}:{type}),required:true});if(type==='number')input.step='any';
 parent.append(node('div',{className:'property-field'},node('label',{htmlFor:id,textContent:label}),input));return input;
}
function options(input,entries,value){input.replaceChildren(...entries.map(([id,name])=>node('option',{value:String(id),textContent:name})));input.value=value===undefined?'':String(value);}
function settings(parent,prefix,t){
 const name=field(parent,prefix+'name',t.clipName),fps=field(parent,prefix+'fps',t.clipFPS,'number'),frames=field(parent,prefix+'frames',t.clipFrames,'number'),mode=field(parent,prefix+'mode',t.clipMode,'select');
 fps.min='0';fps.max='240';frames.min='1';frames.step='1';options(mode,[['loop',t.clipLoop],['mirror',t.clipMirror],['single',t.clipSingle]],'loop');
 for(const input of [name,fps,frames,mode])input.setAttribute('aria-describedby','model-clip-timing-note');return {name,fps,frames,mode};
}
const setValues=(fields,clip)=>{fields.name.value=clip?.name??'';fields.fps.value=String(clip?.fps??30);fields.frames.value=String(clip?.frameCount??30);fields.mode.value=clip?.mode??'loop';};
const values=fields=>({name:fields.name.value,fps:fields.fps.valueAsNumber,frameCount:fields.frames.valueAsNumber,mode:fields.mode.value});
function dialog(id,title,t){
 const element=node('dialog',{id,className:'model-dialog'}),form=node('form',{id:id+'-form'}),heading=node('h3',{id:id+'-title',textContent:title});form.append(heading);element.setAttribute('aria-labelledby',heading.id);element.append(form);document.body.append(element);
 const actions=()=>form.append(node('div',{className:'model-actions'},node('button',{id:id+'-confirm',type:'submit',textContent:t.apply}),node('button',{id:id+'-cancel',type:'button',textContent:t.cancel})));
 return {element,form,heading,actions};
}
export function initializeClipsView(t,parent){
 const details=node('details',{id:'model-clips-details'},node('summary',{textContent:t.clipLibrary}));parent.append(details);
 const select=field(details,'model-clip-select',t.clips,'select'),status=node('p',{id:'model-clip-status',className:'model-note'}),error=node('p',{id:'model-clip-error',className:'image-mesh-error'});error.setAttribute('role','alert');details.append(status,error);
 const form=node('form',{id:'model-clip-form'}),fieldset=node('fieldset'),fields=settings(fieldset,'model-clip-',t);form.append(fieldset);details.append(form);
 fieldset.append(node('p',{id:'model-clip-timing-note',className:'model-note',textContent:t.clipTimingNote}),node('p',{id:'model-clip-duration',className:'model-note'}),node('div',{className:'model-actions'},node('button',{id:'model-clip-apply',type:'submit',textContent:t.apply}),node('button',{id:'model-clip-revert',type:'button',textContent:t.revert})));
 const actions=node('div',{className:'model-actions'});for(const [id,key] of [['create','clipCreate'],['duplicate','clipDuplicate'],['delete','clipDelete'],['preview','clipPreview'],['use','clipUse'],['default','clipDefault']])actions.append(node('button',{id:'model-clip-'+id,type:'button',textContent:t[key]}));details.append(actions,node('p',{className:'model-note',textContent:t.clipPreviewNote}));
 const create=dialog('model-clip-create-dialog',t.clipCreate,t);create.form.append(node('p',{textContent:t.clipCreateNote}));const createdFields=settings(create.form,'model-clip-new-',t);createdFields.name.autofocus=true;create.actions();
 const deleted=dialog('model-clip-delete-dialog',t.clipDeleteTitle,t),deleteNote=node('p',{textContent:t.clipDeleteNote}),impact=node('p',{id:'model-clip-delete-impact'});deleted.form.append(deleteNote,impact);const replacement=field(deleted.form,'model-clip-replacement',t.clipReplacement,'select');deleted.actions();$('model-clip-delete-dialog-cancel').autofocus=true;
 const playback=dialog('model-clip-playback-dialog',t.clipPlaybackTitle,t),playbackNote=node('p'),playbackName=node('p');playback.form.append(playbackNote,playbackName);playback.actions();$('model-clip-playback-dialog-cancel').autofocus=true;
 let supported=false,hasClip=false,duplicating=false,replacementNeeded=false;
 return {values:()=>values(fields),newValues:()=>values(createdFields),replacement:()=>replacementNeeded?Number(replacement.value):undefined,
  render({clips,clip,draft,unsupported,layer}){
   supported=!unsupported;hasClip=Boolean(clip);error.textContent=unsupported?`${t.clipUnsupported} ${unsupported}`:'';
   options(select,clips.length?clips.map(c=>[c.id,`${c.name} · #${c.id}`]):[['',t.clipNone]],clip?.id);select.disabled=!supported||!hasClip;
   if(!draft)setValues(fields,clip);$('model-clip-duration').textContent=clip?`${t.clipDuration}: ${clip.frameCount/clip.fps}`:'';
   const assigned=layer?.animationlayers;status.textContent=`${t.clipSaved}: ${assigned===undefined||Array.isArray(assigned)&&!assigned.length?t.clipDefault:JSON.stringify(assigned)}`;
   fieldset.disabled=!supported||!hasClip;
  },showCreate(clip,duplicate=false){duplicating=duplicate;create.heading.textContent=duplicate?t.clipDuplicate:t.clipCreate;setValues(createdFields,duplicate?{...clip,name:clip.name+' copy'}:{name:t.clipNewName,fps:30,frameCount:30,mode:'loop'});for(const input of [createdFields.fps,createdFields.frames,createdFields.mode])input.parentElement.hidden=duplicate;create.element.showModal();},
  showDelete(clips,clip,references){replacementNeeded=clips[0]?.id===clip.id&&clips.length>1;replacement.parentElement.hidden=!replacementNeeded;replacement.required=replacementNeeded;options(replacement,[['',t.clipReplacement],...clips.filter(c=>c.id!==clip.id).map(c=>[c.id,c.name])],'');
   impact.textContent=`${clip.name} · ${clips.length===1?t.clipLastNote:''}\n${t.clipDefaults}: ${references.defaults.map(l=>l.name??String(l.id)).join(', ')||'0'}\n${t.clipReferences}: ${references.layers.filter(l=>l.referenced.includes(clip.id)).map(l=>l.name??String(l.id)).join(', ')||'0'}`;deleted.element.showModal();},
  showPlayback(clip){playbackNote.textContent=clip?t.clipPlaybackNote:t.clipDefaultNote;playbackName.textContent=clip?`${clip.name} · #${clip.id}`:t.clipDefault;playback.element.showModal();},
  closeCreate:()=>create.element.close(),closeDelete:()=>deleted.element.close(),closePlayback:()=>playback.element.close(),
  busy(value){select.disabled=value||!supported||!hasClip;fieldset.disabled=value||!supported||!hasClip;
   for(const button of actions.querySelectorAll('button'))button.disabled=value||!supported||(!hasClip&&!['model-clip-create','model-clip-default'].includes(button.id));
   for(const d of [create,deleted,playback]){for(const input of d.form.querySelectorAll('input,select,button'))input.disabled=value;
    if(!value&&d.element.open&&!d.form.contains(document.activeElement))d.form.querySelector('[autofocus]')?.focus();}
   if(duplicating)for(const input of [createdFields.fps,createdFields.frames,createdFields.mode])input.disabled=true;
   replacement.disabled=value||!replacementNeeded;
  }
 };
}
