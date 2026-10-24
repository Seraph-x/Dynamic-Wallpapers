import { initializeImagePuppetView } from './image-puppet-view.mjs';
const $=id=>document.getElementById(id);
const node=(tag,properties={},...children)=>{const element=Object.assign(document.createElement(tag),properties);element.append(...children);return element;};
function field(parent,id,title,type='text',value='') {
  const input=node(type==='select'?'select':'input',{id,name:id,...(type==='select'?{}:{type,value})});
  if(type==='number')input.step='any';
  parent.append(node('div',{className:'property-field'},node('label',{htmlFor:id,textContent:title}),input));return input;
}
const options=(input,items,value)=>{input.replaceChildren(...items.map(([value,text])=>node('option',{value:String(value),textContent:text})));input.value=String(value);};
function form(parent,id,title) {
  const fieldset=node('fieldset',{},node('legend',{textContent:title})),form=node('form',{id},fieldset);parent.append(form);return fieldset;
}
function actions(parent,apply,revert,t) {
  parent.append(node('div',{className:'model-actions'},node('button',{id:apply,type:'submit',textContent:t.apply}),
    node('button',{id:revert,type:'button',textContent:t.revert})));
}
function dialog(id,title,t) {
  const element=node('dialog',{id,className:'model-dialog'}),form=node('form',{id:id+'-form'},node('h3',{id:id+'-title',textContent:title}));
  element.setAttribute('aria-labelledby',id+'-title');element.append(form);document.body.append(element);return {element,form};
}
function canParent(candidate,selected,bones) {
  let current=candidate;
  while(current!==-1){if(current===selected)return false;current=bones[current].parent;}return true;
}
export function initializeModelView(t) {
  const panel=$('model-panel');panel.append(node('p',{id:'model-empty',className:'model-note',textContent:t.modelEmpty}));
  panel.append(node('div',{id:'model-recovery',className:'model-actions',hidden:true},node('button',{id:'model-recover',type:'button',textContent:t.revert}),node('button',{id:'model-reload',type:'button',textContent:t.reloadModel})));
  const body=node('div',{id:'model-body',hidden:true});panel.append(body);
  body.append(node('p',{id:'model-summary',className:'model-note'}),node('p',{id:'model-capacity',className:'model-note'}),node('p',{className:'model-note',textContent:t.sharedModel}));
  const overlay=field(body,'model-show-bones',t.showBones,'checkbox');overlay.checked=true;
  body.append(node('ol',{id:'model-bones',className:'model-bones'}));
  const bone=form(body,'model-bone-form',t.bones);field(bone,'model-bone-name',t.boneName).required=true;field(bone,'model-bone-parent',t.boneParent,'select');
  const note=node('p',{id:'model-parent-note',className:'model-note',textContent:t.localTransformNote});bone.append(note);
  $('model-bone-parent').setAttribute('aria-describedby','model-parent-note');actions(bone,'model-bone-apply','model-bone-revert',t);
  body.append(node('div',{className:'model-actions'},node('button',{id:'model-create',type:'button',textContent:t.createBone}),node('button',{id:'model-delete',type:'button',className:'danger-button',textContent:t.deleteBone})));
  body.append(node('p',{className:'section-caption',textContent:t.restTransform}),node('pre',{id:'model-rest-matrix',tabIndex:0}));
  const skin=form(body,'model-weights-form',t.bindMesh);field(skin,'model-skin-mesh',t.mesh,'select');
  skin.append(node('p',{id:'model-skin-error',className:'model-note'}));
  const controls=node('div',{id:'model-skin-controls'});skin.append(controls);
  controls.append(node('canvas',{id:'model-weight-map',width:320,height:180,tabIndex:0}),node('p',{id:'model-map-hint',className:'model-note',textContent:t.vertexHint}));
  $('model-weight-map').setAttribute('aria-label',t.bindMesh);$('model-weight-map').setAttribute('aria-describedby','model-map-hint');
  const vertex=field(controls,'model-vertex',t.vertex,'number');vertex.min='0';vertex.step='1';vertex.required=true;
  for(let i=0;i<4;i++){
    const row=node('div',{className:'model-influence'});controls.append(row);field(row,`model-joint-${i}`,`${t.joint} ${i+1}`,'select');
    const input=field(row,`model-weight-${i}`,`${t.weight} ${i+1}`,'number');input.min='0';input.required=true;
  }
  actions(controls,'model-weights-apply','model-weights-revert',t);
  const created=dialog('model-create-dialog',t.createBone,t);
  field(created.form,'model-new-name',t.boneName).required=true;$('model-new-name').autofocus=true;
  field(created.form,'model-new-parent',t.boneParent,'select');
  for(const [prefix,title,defaultValue] of [['t',t.position,0],['r',t.rotation+' (°)',0],['s',t.scaleTrack,1]]){
    const group=node('fieldset',{className:'model-trs'},node('legend',{textContent:title}));created.form.append(group);
    for(const axis of ['x','y','z'])field(group,`model-new-${prefix}${axis}`,axis.toUpperCase(),'number',String(defaultValue)).required=true;
  }
  actions(created.form,'model-new-confirm','model-new-cancel',{...t,apply:t.createBone,revert:t.cancel});
  const deleted=dialog('model-delete-dialog',t.deleteBoneTitle,t);
  deleted.form.append(node('p',{textContent:t.deleteBoneDetail}),node('p',{id:'model-delete-impact'}));
  deleted.element.setAttribute('aria-describedby','model-delete-impact');
  field(deleted.form,'model-delete-replacement',t.replacementBone,'select');
  actions(deleted.form,'model-delete-confirm','model-delete-cancel',{...t,apply:t.deleteBone,revert:t.cancel});
  $('model-delete-cancel').autofocus=true;
  const image=initializeImagePuppetView(t,panel);
  return {showImage:()=>image.show(),imageValues:()=>image.values(),imageError:message=>image.error(message),closeImage:()=>image.close(),render({data,bone,mesh,vertex,capacity,boneDraft,weightDraft,onBone,loading,error,canCreateImage}){
    image.available(canCreateImage);
    $('model-empty').hidden=Boolean(data);$('model-empty').textContent=error??(loading?t.modelLoading:canCreateImage?t.imageMeshHint:t.modelEmpty);$('model-recovery').hidden=!error;body.hidden=!data;if(!data)return;
    $('model-summary').textContent=`${data.bones.length} ${t.bones} · ${data.meshes.length} ${t.mesh} · ${data.animations.length} ${t.clips} · ${data.attachments.length} ${t.attachments}`;
    $('model-capacity').textContent=capacity?`${t.modelCapacity}: ${capacity}`:t.modelCapacityMissing;$('model-capacity').dataset.capacity=capacity??'';
    const focused=document.activeElement?.dataset.bone;
    $('model-bones').replaceChildren(...data.bones.map((value,i)=>{
      const button=node('button',{type:'button',textContent:String(value.name),title:`${i}: ${String(value.name)}`});button.dataset.bone=i;button.setAttribute('aria-pressed',String(bone===i));
      let depth=0,parent=value.parent;while(parent>=0){depth++;parent=data.bones[parent]?.parent??-1;}button.style.paddingLeft=`${8+depth*10}px`;button.addEventListener('click',()=>onBone(i));return node('li',{},button);
    }));
    if(focused!==undefined)$('model-bones').querySelector(`[data-bone="${focused}"]`)?.focus();
    const value=data.bones[bone];
    if(!boneDraft){$('model-bone-name').value=String(value.name);options($('model-bone-parent'),[[-1,t.rootBone],...data.bones.flatMap((b,i)=>canParent(i,bone,data.bones)?[[i,`${i}: ${String(b.name)}`]]:[])],value.parent);}
    $('model-rest-matrix').textContent=Array.from({length:4},(_,row)=>Array.from({length:4},(_,column)=>Number(value.matrix[column*4+row].toPrecision(5))).join('  ')).join('\n');
    $('model-delete').disabled=data.bones.length===1;
    options($('model-skin-mesh'),data.meshes.map((m,i)=>[i,`${t.mesh} ${i+1}${m.vertexCount?` · ${m.vertexCount}`:''}`]),mesh);
    const geometry=data.meshes[mesh];$('model-skin-error').textContent=geometry?.error??'';$('model-skin-controls').hidden=!geometry?.vertexCount;
    if(geometry?.vertexCount && !weightDraft){
      $('model-vertex').max=geometry.vertexCount-1;$('model-vertex').value=vertex;
      for(let i=0;i<4;i++){
        const weight=geometry.weights[vertex*4+i];options($(`model-joint-${i}`),[['',t.unusedJoint],...data.bones.map((b,id)=>[id,`${id}: ${String(b.name)}`])],weight>0?geometry.joints[vertex*4+i]:'');$(`model-weight-${i}`).value=weight;
      }
    }
  },showCreate(data,bone){
    $('model-new-name').value=t.newBone;options($('model-new-parent'),[[-1,t.rootBone],...data.bones.map((b,i)=>[i,`${i}: ${String(b.name)}`])],bone);
    for(const prefix of ['t','r','s'])for(const axis of ['x','y','z'])$(`model-new-${prefix}${axis}`).value=prefix==='s'?'1':'0';created.element.showModal();
  },showDelete(data,bone,impact){
    $('model-delete-impact').textContent=`${String(data.bones[bone].name)} · ${t.weightedVertices}: ${impact.vertices} · ${t.attachments}: ${impact.attachments} · ${t.childBones}: ${impact.children}`;
    const input=$('model-delete-replacement'),needed=impact.vertices>0||impact.attachments>0;
    input.parentElement.hidden=!needed;input.required=needed;input.disabled=!needed;
    options(input,[['',t.chooseBone],...data.bones.flatMap((b,i)=>i===bone?[]:[[i,`${i}: ${String(b.name)}`]])],'');deleted.element.showModal();
  },busy(value){for(const control of panel.querySelectorAll('fieldset, #model-create, #model-recover, #model-reload'))control.disabled=value;
    $('model-image-create').disabled=value;image.busy(value);
    $('model-delete').disabled=value||$('model-bones').children.length===1;
    for(const button of $('model-bones').querySelectorAll('button'))button.disabled=value;
    for(const element of [created.form,deleted.form])for(const control of element.querySelectorAll('input,select,button'))if(!control.id.endsWith('cancel'))control.disabled=value;
    if(!value)for(const dialog of [created.element,deleted.element])if(dialog.open&&document.activeElement===dialog)dialog.querySelector('[autofocus]')?.focus();
  }};
}
