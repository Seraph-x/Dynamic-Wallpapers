const node=(tag,properties={},...children)=>{const element=Object.assign(document.createElement(tag),properties);element.append(...children);return element;};
export function initializeWeightBrushView(t,parent) {
  const form=node('form',{id:'model-brush-form',className:'model-brush-controls'}),fields=node('fieldset',{},node('legend',{textContent:t.weightBrush}));form.append(fields);
  const mode=node('select',{id:'model-map-tool',name:'map-tool'},node('option',{value:'select',textContent:t.selectVertex}),node('option',{value:'paint',textContent:t.paintWeights}));
  fields.append(node('div',{className:'property-field'},node('label',{htmlFor:mode.id,textContent:t.mapTool}),mode));
  const parameters=node('div',{id:'model-brush-parameters',hidden:true});fields.append(parameters);
  for(const [key,title,value,min,max] of [['radius',t.brushRadius,24,0,undefined],['target',t.brushTarget,1,0,1],['strength',t.brushStrength,.5,0,1]]){
    const input=node('input',{id:`model-brush-${key}`,name:key,type:'number',value:String(value),step:'any',min:String(min),required:true});if(max!==undefined)input.max=String(max);
    input.setAttribute('aria-describedby','model-brush-hint');parameters.append(node('div',{className:'property-field'},node('label',{htmlFor:input.id,textContent:title}),input));
  }
  const hint=node('p',{id:'model-brush-hint',className:'model-note',textContent:t.brushHint});parameters.append(hint);parent.append(form);
  form.addEventListener('submit',e=>e.preventDefault());
  mode.addEventListener('change',()=>{parameters.hidden=mode.value!=='paint';document.getElementById('model-weight-map').dataset.tool=mode.value;});
}
export function drawBrushCursor(canvas,center,radius) {
  if(!center)return;const context=canvas.getContext('2d');context.strokeStyle='#faf0d6';context.lineWidth=1;context.beginPath();context.arc(...center,radius,0,Math.PI*2);context.stroke();
}
