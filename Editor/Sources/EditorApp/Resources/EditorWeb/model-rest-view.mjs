import { restPose } from './model-api.mjs';
const node=(tag,properties={},...children)=>{const element=Object.assign(document.createElement(tag),properties);element.append(...children);return element;};
export function initializeRestTransformView(t,parent) {
  const details=node('details',{id:'model-rest-details'},node('summary',{textContent:t.restEditing}));parent.append(details);
  const form=node('form',{id:'model-rest-form'}),fields=node('fieldset'),inputs=[];form.append(fields);details.append(form);
  fields.append(node('p',{id:'model-rest-hint',className:'model-note',textContent:t.restHint}));
  for(const [prefix,title] of [['t',t.position],['r',t.rotation+' (°)'],['s',t.scaleTrack]]){
    const group=node('fieldset',{className:'model-trs'},node('legend',{textContent:title}));fields.append(group);
    for(const axis of ['x','y','z']){
      const id=`model-rest-${prefix}${axis}`,input=node('input',{id,name:id,type:'number',step:'any',required:true});input.setAttribute('aria-describedby','model-rest-hint');inputs.push(input);
      group.append(node('div',{className:'property-field'},node('label',{htmlFor:id,textContent:axis.toUpperCase()}),input));
    }
  }
  fields.append(node('div',{className:'model-actions'},node('button',{id:'model-rest-apply',type:'submit',textContent:t.apply}),node('button',{id:'model-rest-revert',type:'button',textContent:t.revert})));
  const error=node('p',{id:'model-rest-error',className:'model-note'});details.append(error,node('p',{className:'section-caption',textContent:t.restTransform}),node('pre',{id:'model-rest-matrix',tabIndex:0}));
  let supported=false,locked=false,canonical;
  return {render(matrix,draft){
    document.getElementById('model-rest-matrix').textContent=Array.from({length:4},(_,row)=>Array.from({length:4},(_,column)=>Number(matrix[column*4+row].toPrecision(5))).join('  ')).join('\n');
    try{const pose=restPose(matrix);supported=true;error.textContent='';if(!draft){canonical=pose;inputs.forEach((input,i)=>{input.value=String(pose[i]*(i>=3&&i<6?180/Math.PI:1));});}}
    catch(value){supported=false;error.textContent=({REST_FINITE:t.restFinite,REST_INVERSE:t.restInverse,REST_PERSPECTIVE:t.restPerspective,REST_SHEAR:t.restShear})[value.code]??value.message;if(!draft)inputs.forEach(input=>{input.value='';});}
    fields.disabled=locked||!supported;
  },values(){return inputs.map((input,i)=>{const factor=i>=3&&i<6?180/Math.PI:1;return input.valueAsNumber===canonical[i]*factor?canonical[i]:input.valueAsNumber/factor;});},busy(value){locked=value;fields.disabled=value||!supported;}};
}
