const node=(tag,text)=>{const element=document.createElement(tag);if(text!==undefined)element.textContent=text;return element;};
export class PropertyBindingView {
  dialog;form;fields;property;condition;apply;remove;cancel;#t;#state;#default;#conditionField;#numeric;#error;
  constructor(t){
    this.#t=t;this.dialog=node('dialog');this.dialog.id='property-binding-dialog';this.dialog.setAttribute('aria-labelledby','property-binding-title');
    const title=node('h2',t.bindingTitle);title.id='property-binding-title';
    const note=node('p',t.bindingFallback);note.id='property-binding-note';this.dialog.setAttribute('aria-describedby',note.id);
    this.form=node('form');this.form.noValidate=true;this.fields=node('fieldset');this.fields.className='binding-fields';
    this.property=node('select');this.property.id='property-binding-name';this.property.name='property';this.property.required=true;
    const label=node('label',t.bindingProperty);label.htmlFor=this.property.id;
    const unavailable=node('details');unavailable.id='property-binding-unavailable';unavailable.append(node('summary',t.bindingUnavailable),node('ul'));
    const defaultTitle=node('h3',t.bindingDefault);this.#default=node('pre');this.#default.id='property-binding-default';
    this.#conditionField=node('div');this.condition=node('select');this.condition.id='property-binding-condition';this.condition.name='condition';
    const conditionLabel=node('label',t.bindingCondition);conditionLabel.htmlFor=this.condition.id;this.#conditionField.append(conditionLabel,this.condition);
    this.#numeric=node('p',t.bindingNumeric);this.#numeric.className='binding-help';
    const warning=node('p');warning.id='property-binding-warning';
    const loadNote=node('p',t.bindingLoadTime);loadNote.id='property-binding-load-note';loadNote.className='binding-help';
    const currentTitle=node('h3',t.bindingCurrent),current=node('pre');current.id='property-binding-current';
    this.#error=node('p');this.#error.id='property-binding-error';this.#error.setAttribute('role','alert');this.#error.tabIndex=-1;
    const actions=node('div');actions.className='binding-actions';
    this.cancel=this.#button('cancel',t.bindingCancel);this.remove=this.#button('remove',t.bindingRemove);this.apply=this.#button('apply',t.bindingApply);this.apply.type='submit';this.apply.className='primary-button';
    actions.append(this.cancel,this.remove,this.apply);
    this.fields.append(label,this.property,unavailable,defaultTitle,this.#default,this.#conditionField,this.#numeric,loadNote,warning,currentTitle,current,actions);
    this.form.append(this.#error,this.fields);this.dialog.append(title,note,this.form);document.body.append(this.dialog);
    this.property.addEventListener('change',()=>this.#selection());
  }
  #button(name,text){const button=node('button',text);button.type='button';button.id='property-binding-'+name;return button;}
  show(state){
    this.#state=state;this.error('');this.property.replaceChildren();
    document.getElementById('property-binding-load-note').hidden=!['text','pointsize'].includes(state.field);
    const placeholder=node('option',this.#t.bindingChoose);placeholder.value='';placeholder.disabled=true;this.property.append(placeholder);
    for(const row of state.choices){const option=node('option',`${row.text??row.name} · ${row.name}${row.incompatible?' — '+this.#t.bindingUnavailable:''}`);option.value=row.name;option.disabled=Boolean(row.incompatible);option.title=row.incompatible??'';this.property.append(option);}
    const unavailable=document.getElementById('property-binding-unavailable');unavailable.hidden=!state.choices.some(row=>row.incompatible);unavailable.querySelector('ul').replaceChildren(...state.choices.filter(row=>row.incompatible).map(row=>node('li',`${row.name}: ${row.incompatible}`)));
    const current=state.choices.find(row=>row.name===state.currentName&&!row.incompatible);
    this.property.value=current?.name??'';this.property.disabled=Boolean(state.reason||state.metadataError);
    this.remove.hidden=!state.hasUser;this.remove.disabled=Boolean(state.reason);this.apply.disabled=Boolean(state.reason||state.metadataError);
    document.getElementById('property-binding-current').textContent=state.present?JSON.stringify(state.raw,null,2):JSON.stringify(state.base);
    document.getElementById('property-binding-warning').textContent=[state.controls.length?this.#t.bindingReplace+' '+state.controls.join(', '):'',state.currentError?this.#t.bindingExisting+' '+state.currentError:'',state.reason||state.metadataError?this.#t.bindingInspect+' '+(state.reason??state.metadataError):''].filter(Boolean).join('\n');
    this.#selection(state.condition);this.dialog.showModal();this.cancel.focus();
  }
  #selection(condition){
    const row=this.#state.choices.find(row=>row.name===this.property.value&&!row.incompatible);
    this.#default.textContent=row?JSON.stringify(row.value):'';
    const conditional=this.#state.field==='visible'&&row?.type==='combo';this.#conditionField.hidden=!conditional;this.#numeric.hidden=!conditional;
    this.condition.replaceChildren();
    if(conditional){for(const item of row.options){const option=node('option',`${item.label} · ${item.value}`);option.value=item.value;this.condition.append(option);}if(typeof condition==='string')this.condition.value=condition;}
  }
  values(){
    if(!this.form.reportValidity())throw new Error(this.#t.bindingInvalid);
    const row=this.#state.choices.find(row=>row.name===this.property.value&&!row.incompatible);
    if(!row)throw new Error(this.#t.bindingInvalid);
    const conditional=this.#state.field==='visible'&&row.type==='combo';
    if(conditional&&this.condition.selectedIndex<0)throw new Error(this.#t.bindingInvalid);
    return {name:row.name,...(conditional?{condition:this.condition.value}:{})};
  }
  error(value){this.#error.textContent=value??'';}
  locked(value){this.fields.disabled=value;}
  close(){this.dialog.close();}
  destroy(){this.dialog.remove();}
}
