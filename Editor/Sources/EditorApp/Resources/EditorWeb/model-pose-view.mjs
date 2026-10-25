const node=(tag,properties={},...children)=>{const e=Object.assign(document.createElement(tag),properties);e.append(...children);return e;};
function number(parent,id,label){
 const input=node('input',{id,name:id,type:'number',step:'any',required:true});input.setAttribute('aria-describedby','model-pose-note');
 parent.append(node('div',{className:'property-field'},node('label',{htmlFor:id,textContent:label}),input));return input;
}
export function initializePoseView(t,parent){
 const details=node('details',{id:'model-poses-details'},node('summary',{textContent:t.poseFrames}));parent.append(details);
 details.append(node('p',{id:'model-pose-note',className:'model-note',textContent:t.poseNote}));
 const frame=number(details,'model-pose-frame',t.poseFrame);frame.min='0';frame.step='1';
 const status=node('p',{id:'model-pose-status',className:'model-note'}),error=node('p',{id:'model-pose-error',className:'model-note'});error.setAttribute('role','alert');details.append(status,error);
 const form=node('form',{id:'model-pose-form'}),fields=node('fieldset'),inputs=[];form.append(fields);details.append(form);
 for(const [prefix,title] of [['t',t.position],['r',t.rotation+' (°)'],['s',t.scaleTrack]]){
  const group=node('fieldset',{className:'model-trs'},node('legend',{textContent:title}));fields.append(group);
  for(const axis of ['x','y','z'])inputs.push(number(group,`model-pose-${prefix}${axis}`,axis.toUpperCase()));
 }
 const actions=node('div',{className:'model-actions'});fields.append(actions);
 for(const [id,title,type] of [['apply',t.apply,'submit'],['revert',t.revert,'button'],['copy',t.poseCopy,'button'],['paste',t.posePaste,'button'],['reset',t.poseReset,'button'],['preview',t.posePreview,'button']])actions.append(node('button',{id:'model-pose-'+id,type,textContent:title}));
 const rangeForm=node('form',{id:'model-pose-range-form'}),range=node('fieldset');rangeForm.append(range);details.append(rangeForm);range.append(node('p',{className:'model-note',textContent:t.poseBakeNote}));
 const start=number(range,'model-pose-start',t.poseStart),end=number(range,'model-pose-end',t.poseEnd);for(const input of [start,end]){input.min='0';input.step='1';}
 range.append(node('button',{id:'model-pose-interpolate',type:'submit',textContent:t.poseBake}));details.append(node('p',{className:'model-note',textContent:t.poseLoopNote}));
 let canonical,supported=false,clipboard=false,locked=false,context;
 function busy(){frame.disabled=locked||!supported;fields.disabled=locked||!supported;range.disabled=locked||!supported;document.getElementById('model-pose-paste').disabled=locked||!supported||!clipboard;}
 function setPose(pose){canonical=[...pose];inputs.forEach((input,i)=>input.value=String(pose[i]*(i>=3&&i<6?180/Math.PI:1)));}
 return {values:()=>inputs.map((input,i)=>{const factor=i>=3&&i<6?180/Math.PI:1;return input.valueAsNumber===canonical[i]*factor?canonical[i]:input.valueAsNumber/factor;}),
  setPose,range:()=>({start:start.valueAsNumber,end:end.valueAsNumber}),
  render({info,draft,reason,bone,hasClipboard}){
   supported=Boolean(info);clipboard=hasClipboard;error.textContent=reason??(!info?t.poseUnavailable:'');
   if(info){frame.max=String(info.frameCount);frame.value=String(info.frame);status.textContent=`${bone} · ${t.poseFrame} ${info.frame}/${info.frameCount} · ${info.time}s`;
    if(!draft)setPose(info.pose);
    const next=`${info.clip}/${info.frameCount}`;if(context!==next){start.value='0';end.value=String(info.frameCount);start.max=end.max=String(info.frameCount);context=next;}
   }else{status.textContent='';frame.value='';if(!draft)inputs.forEach(input=>input.value='');}
   busy();
  },busy(value){locked=value;busy();}
 };
}
