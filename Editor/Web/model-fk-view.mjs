const node=(tag,props={},...children)=>{const e=Object.assign(document.createElement(tag),props);e.append(...children);return e;};
function field(parent,id,label,frame=false){
 const input=node('input',{id,name:id,type:'number',step:frame?'1':'any',required:true});if(frame)input.min='0';input.setAttribute('aria-describedby','model-fk-note');
 parent.append(node('div',{className:'property-field'},node('label',{htmlFor:id,textContent:label}),input));return input;
}
export function initializeFkView(t,parent){
 const entry=node('div',{id:'model-fk-entry'}),open=node('button',{id:'model-fk-open',type:'button',textContent:t.fkTitle}),unavailable=node('p',{className:'model-note'});entry.append(open,unavailable);parent.append(entry);
 const dialog=node('dialog',{id:'model-fk-dialog',className:'model-dialog'}),form=node('form',{id:'model-fk-form'}),heading=node('h3',{id:'model-fk-title',textContent:t.fkTitle});dialog.setAttribute('aria-labelledby',heading.id);
 form.append(heading,node('p',{id:'model-fk-note',className:'model-note',textContent:t.fkNote}),node('p',{className:'model-note',textContent:t.fkLoopNote}));
 const context=node('p',{id:'model-fk-context',className:'model-note'});form.append(context);
 const range=node('fieldset',{className:'model-trs'},node('legend',{textContent:t.fkRange}));form.append(range);
 const start=field(range,'model-fk-start',t.poseStart,true),end=field(range,'model-fk-end',t.poseEnd,true),frame=field(range,'model-fk-frame',t.poseFrame,true);start.autofocus=true;
 const inputs=[];
 for(const [prefix,label] of [['t',t.position],['r',t.rotation+' (°)'],['s',t.scaleTrack]]){
  const group=node('fieldset',{className:'model-trs'},node('legend',{textContent:label}));form.append(group);
  for(const axis of ['x','y','z'])inputs.push(field(group,`model-fk-${prefix}${axis}`,axis.toUpperCase()));
 }
 const error=node('p',{id:'model-fk-error',className:'image-mesh-error'});error.setAttribute('role','alert');form.append(error);
 form.append(node('div',{className:'model-actions'},node('button',{id:'model-fk-preview',type:'button',textContent:t.posePreview}),node('button',{id:'model-fk-confirm',type:'submit',textContent:t.fkBake}),node('button',{id:'model-fk-cancel',type:'button',textContent:t.cancel})));dialog.append(form);document.body.append(dialog);
 let supported=false,locked=false,restoreFocus=false;
 function busy(){open.disabled=locked||!supported;if(restoreFocus&&!locked&&supported&&!dialog.open){restoreFocus=false;open.focus();}for(const input of form.querySelectorAll('input,button'))input.disabled=locked;if(!locked&&dialog.open&&!form.contains(document.activeElement))start.focus();}
 return {render({available,reason}){supported=available;unavailable.textContent=reason??'';busy();},show({clip,bone,frameCount}){context.textContent=`${clip} · ${bone}`;start.value=frame.value='0';end.value=String(frameCount);for(const input of [start,end,frame])input.max=String(frameCount);inputs.forEach((input,i)=>input.value=i>=6?'1':'0');error.textContent='';dialog.showModal();},
  values:()=>({start:start.valueAsNumber,end:end.valueAsNumber,frame:frame.valueAsNumber,delta:inputs.map((input,i)=>input.valueAsNumber*(i>=3&&i<6?Math.PI/180:1))}),error(message){error.textContent=message;},close(){restoreFocus=true;dialog.close();},busy(value){locked=value;busy();}
 };
}
