const node=(tag,props={},...children)=>{const e=Object.assign(document.createElement(tag),props);e.append(...children);return e;};
const $=id=>document.getElementById(id);
function field(parent,id,label,type='text',required=false){const input=node(type==='select'?'select':'input',{id,name:id,...(type==='select'?{}:{type}),required});if(type==='number')input.step='any';input.setAttribute('aria-describedby','model-mix-note');parent.append(node('div',{className:'property-field'},node('label',{htmlFor:id,textContent:label}),input));return input;}
function options(input,entries,value){input.replaceChildren(...entries.map(([value,text])=>node('option',{value:String(value),textContent:text})));input.value=String(value??'');}
export function initializeMixingView(t,parent){
 const details=node('details',{id:'model-mixing-details'},node('summary',{textContent:t.mixLayers}));parent.append(details);
 details.append(node('p',{id:'model-mix-note',className:'model-note',textContent:t.mixNote}));const select=field(details,'model-mix-select',t.mixLayer,'select');
 const error=node('p',{id:'model-mix-error',className:'image-mesh-error'});error.setAttribute('role','alert');details.append(error);
 const form=node('form',{id:'model-mix-form'}),fieldset=node('fieldset');form.append(fieldset);details.append(form);
 const fields={name:field(fieldset,'model-mix-name',t.name),animation:field(fieldset,'model-mix-clip',t.clips,'select',true),blend:field(fieldset,'model-mix-blend',t.mixWeight,'number',true),rate:field(fieldset,'model-mix-rate',t.mixRate,'number',true),visible:field(fieldset,'model-mix-visible',t.visible,'checkbox'),additive:field(fieldset,'model-mix-additive',t.mixAdditive,'checkbox')};
 fieldset.append(node('div',{className:'model-actions'},node('button',{id:'model-mix-apply',type:'submit',textContent:t.apply}),node('button',{id:'model-mix-revert',type:'button',textContent:t.revert})));
 const raw=node('pre',{id:'model-mix-raw',tabIndex:0});details.append(raw);
 const actions=node('div',{className:'model-actions'});for(const [id,title] of [['duplicate',t.duplicate],['up',t.up],['down',t.down],['remove',t.remove]])actions.append(node('button',{id:'model-mix-'+id,type:'button',textContent:title}));details.append(actions);
 const add=field(details,'model-mix-add-clip',t.mixAddClip,'select');details.append(node('button',{id:'model-mix-add',type:'button',textContent:t.mixAdd}),node('p',{className:'model-note',textContent:t.mixAdditiveNote}));
 const dialog=node('dialog',{id:'model-mix-remove-dialog',className:'model-dialog'}),removeForm=node('form',{id:'model-mix-remove-form'}),heading=node('h3',{id:'model-mix-remove-title',textContent:t.mixRemoveTitle}),impact=node('p',{id:'model-mix-remove-impact'});dialog.setAttribute('aria-labelledby',heading.id);dialog.setAttribute('aria-describedby',impact.id);removeForm.append(heading,impact,node('div',{className:'model-actions'},node('button',{id:'model-mix-remove-confirm',type:'submit',textContent:t.remove}),node('button',{id:'model-mix-remove-cancel',type:'button',textContent:t.cancel,autofocus:true})));dialog.append(removeForm);document.body.append(dialog);
 let state={rows:[]},selected,clips=[],locked=false,signature;
 function busy(){const row=state.rows.find(row=>row.index===selected),has=Boolean(row);select.disabled=locked||!state.rows.length;fieldset.disabled=locked||!has||Boolean(row.reason);$('model-mix-revert').disabled=locked||!has;
  for(const [id,disabled] of [['duplicate',!has||Boolean(row?.reason)],['up',!has||selected===0],['down',!has||selected===state.rows.length-1],['remove',!has],['add',Boolean(state.error)||!clips.length]])$('model-mix-'+id).disabled=locked||disabled;
  add.disabled=locked||Boolean(state.error)||!clips.length;for(const button of removeForm.querySelectorAll('button'))button.disabled=locked;
  if(!locked&&dialog.open&&!removeForm.contains(document.activeElement))$('model-mix-remove-cancel').focus();
 }
 return {values:()=>({name:fields.name.value,animation:Number(fields.animation.value),blend:fields.blend.valueAsNumber,rate:fields.rate.valueAsNumber,visible:fields.visible.checked,additive:fields.additive.checked}),
  render(info,index,available,draft){state=info;selected=index;clips=available;const row=info.rows.find(row=>row.index===index);
   options(select,info.rows.length?info.rows.map(row=>[row.index,`${row.index+1}: ${row.values.name||'#'+row.values.animation}`]):[['',t.mixDefault]],index);
   error.textContent=info.error??row?.reason??'';raw.hidden=!row?.reason;raw.textContent=row?.reason?JSON.stringify(row.raw,null,2):'';
   const next=JSON.stringify(available.map(c=>[c.id,c.name]));if(signature!==next){const previous=add.value;options(add,available.map(c=>[c.id,c.name]),available.some(c=>String(c.id)===previous)?previous:available[0]?.id);signature=next;}
   if(!draft){options(fields.animation,available.map(c=>[c.id,c.name]),row?.values.animation);for(const key of ['name','blend','rate'])fields[key].value=row&&!row.reason?String(row.values[key]):'';for(const key of ['visible','additive'])fields[key].checked=Boolean(row&&!row.reason&&row.values[key]);}
   busy();
  },showRemove(row,last){impact.textContent=`${row.values.name||'#'+row.values.animation}. ${last?t.mixRemoveLast:t.mixRemoveNote}`;dialog.showModal();},close:()=>dialog.close(),busy(value){locked=value;busy();}
 };
}
