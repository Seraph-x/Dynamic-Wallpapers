import { imagePuppetStats } from './model-api.mjs';

const node=(tag,properties={},...children)=>{const element=Object.assign(document.createElement(tag),properties);element.append(...children);return element;};
export function initializeImagePuppetView(t,panel) {
  const entry=node('div',{id:'model-image-entry',hidden:true},node('button',{id:'model-image-create',type:'button',textContent:t.imageMeshCreate}));panel.append(entry);
  const dialog=node('dialog',{id:'model-image-dialog',className:'model-dialog'}),form=node('form',{id:'model-image-dialog-form'});
  const title=node('h3',{id:'model-image-title',textContent:t.imageMeshTitle}),note=node('p',{id:'model-image-note',textContent:t.imageMeshNote});
  const root=node('input',{id:'model-image-root',name:'root',type:'text',required:true,autofocus:true});
  root.setAttribute('aria-describedby','model-image-note model-image-error');
  form.append(title,note,node('div',{className:'property-field'},node('label',{htmlFor:root.id,textContent:t.imageRootName}),root));
  const grid=node('fieldset',{className:'image-grid-options'},node('legend',{textContent:t.imageGridDensity})),radios=[];
  for(const cells of [4,8,16,32]){
    const stats=imagePuppetStats({columns:cells,rows:cells}),id=`model-image-grid-${cells}`;
    const radio=node('input',{id,type:'radio',name:'density',value:String(cells),checked:cells===8,required:true});radios.push(radio);
    grid.append(node('label',{htmlFor:id},radio,node('span',{textContent:`${cells} × ${cells} · ${stats.vertices} ${t.imageVertices} · ${stats.triangles} ${t.imageTriangles}`})));
  }
  const error=node('p',{id:'model-image-error',className:'image-mesh-error'});error.setAttribute('role','alert');
  form.append(grid,error,node('div',{className:'model-actions'},node('button',{id:'model-image-confirm',type:'submit',textContent:t.imageMeshConfirm}),node('button',{id:'model-image-cancel',type:'button',textContent:t.cancel})));
  dialog.setAttribute('aria-labelledby',title.id);dialog.setAttribute('aria-describedby',note.id);dialog.append(form);document.body.append(dialog);
  return {available(value){entry.hidden=!value;},show(){root.value=t.imageRootDefault;radios.forEach(r=>{r.checked=r.value==='8';});error.textContent='';dialog.showModal();},
    values(){const cells=Number(radios.find(r=>r.checked)?.value);return {columns:cells,rows:cells,rootName:root.value};},
    error(message){error.textContent=message;},close(){dialog.close();},busy(value){
      for(const input of form.querySelectorAll('input,button'))input.disabled=value;
      if(!value&&dialog.open&&document.activeElement===dialog)root.focus();
    }};
}
