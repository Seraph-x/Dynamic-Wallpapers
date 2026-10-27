const $=id=>document.getElementById(id);
const element=(tag,text)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;return node;};
const types=['bool','slider','color','textinput','combo'];
const typeKeys=['propertyBool','propertySlider','propertyColor','propertyTextInput','propertyCombo'];

export class PropertyWorkspaceView {
  panel;form;list;dialog;#t;#options=[];#optionVisible=[];#initial;#creating=false;#displayed=new Map();#typeInitial;
  constructor(t){
    this.#t=t;this.panel=$('project-panel');
    const hint=element('p',t.propertyHint);hint.className='property-help';
    const heading=element('h3',t.userProperties);heading.id='user-properties-heading';
    this.list=element('select');this.list.id='user-property-list';this.list.setAttribute('aria-labelledby',heading.id);
    const actions=element('div');actions.className='property-actions';
    for(const [name,label]of [['new','propertyNew'],['copy','propertyCopy'],['delete','propertyDelete']])actions.append(this.#button(name,t[label]));
    this.form=element('form');this.form.id='user-property-form';this.form.noValidate=true;
    const error=element('p');error.id='user-property-error';error.setAttribute('role','alert');
    this.panel.append(heading,hint,this.list,actions,error,this.form);
    this.dialog=element('dialog');this.dialog.id='user-property-delete-dialog';this.dialog.setAttribute('aria-labelledby','user-property-delete-title');this.dialog.setAttribute('aria-describedby','user-property-delete-warning');
    const title=element('h2',t.propertyDeleteTitle);title.id='user-property-delete-title';
    const warning=element('p',t.propertyDeleteWarning);warning.id='user-property-delete-warning';
    const identity=element('pre');identity.id='user-property-delete-name';
    const buttons=element('div');buttons.className='property-actions';
    buttons.append(this.#button('delete-cancel',t.propertyCancel),this.#button('delete-confirm',t.propertyDelete));
    this.dialog.append(title,identity,warning,buttons);document.body.append(this.dialog);
  }
  #button(name,text){const node=element('button',text);node.type='button';node.id='user-property-'+name;return node;}
  #field(name,text,{value='',type='text',required=false,disabled=false,textarea=false}={}){
    const wrapper=element('div'),label=element('label',text),input=element(textarea?'textarea':'input');
    wrapper.className='property-field';input.id='user-property-'+name;input.name=name;label.htmlFor=input.id;
    if(!textarea)input.type=type;
    if(type==='checkbox')input.checked=value;else input.value=value;
    if(type==='number')input.step='any';input.required=required;input.disabled=disabled;
    if(name==='key'){input.autocomplete='off';input.spellcheck=false;input.setAttribute('autocorrect','off');input.setAttribute('autocapitalize','off');input.setAttribute('aria-describedby','user-property-key-hint');}
    wrapper.append(label,input);return wrapper;
  }
  showList(rows,name){
    this.list.replaceChildren(...rows.map(row=>{const option=element('option',`${row.text??row.name} · ${row.name}`);option.value=row.name;return option;}));
    if(!rows.length){const option=element('option',this.#t.propertyEmpty);option.value='';this.list.append(option);}
    if(name!==undefined)this.list.value=name;
  }
  show(row,{creating=false,copy=false}={}){
    this.#creating=creating;this.#initial=row;this.#displayed.clear();this.form.replaceChildren();this.error('');
    const readonly=row?.readOnlyReason;
    $('user-property-copy').disabled=!row||Boolean(readonly)||creating;$('user-property-delete').disabled=!row||Boolean(readonly)||creating;
    if(!row)return;
    if(readonly){const note=element('p',this.#t.propertyReadOnly+': '+readonly),raw=element('pre',JSON.stringify(row.raw,null,2));this.form.append(note,raw);return;}
    const type=element('select');type.id='user-property-type';type.name='type';type.disabled=!creating||copy;
    types.forEach((value,i)=>{const option=element('option',this.#t[typeKeys[i]]);option.value=value;type.append(option);});type.value=row.type;
    const typeLabel=element('label',this.#t.propertyType);typeLabel.htmlFor=type.id;
    const keyHint=element('p',this.#t.propertyKeyHint);keyHint.id='user-property-key-hint';keyHint.className='property-help';
    this.form.append(keyHint,this.#field('key',this.#t.propertyKey,{value:creating?'':row.name,required:true,disabled:!creating}),typeLabel,type,
      this.#field('text',this.#t.propertyText,{value:row.text??''}),this.#field('order',this.#t.propertyOrder,{value:row.order??'',type:'number'}));
    const body=element('div');body.id='user-property-type-fields';this.form.append(body);this.typeFields(row);
    const actions=element('div');actions.className='property-actions';const apply=this.#button('apply',this.#t.propertyApply);apply.type='submit';apply.className='primary-button';
    actions.append(apply,this.#button('revert',this.#t.propertyRevert));this.form.append(actions);
    for(const name of ['text','order'])this.#displayed.set(name,$('user-property-'+name).value);
  }
  typeFields(row){
    const body=$('user-property-type-fields');body.replaceChildren();this.#typeInitial=row;this.#options=structuredClone(row.options??[]);
    if(row.type==='combo'){
      const legend=element('h4',this.#t.propertyOptions),options=element('div');options.id='user-property-options';body.append(legend,options,this.#button('add-option',this.#t.propertyAddOption));this.#renderOptions();
      const select=element('select');select.id='user-property-value';select.name='value';const label=element('label',this.#t.propertyDefault);label.htmlFor=select.id;body.append(label,select);this.#updateDefault(row.value);
    }else{
      body.append(this.#field('value',this.#t.propertyDefault,{value:row.value,type:row.type==='bool'?'checkbox':row.type==='slider'?'number':'text',textarea:row.type==='textinput',required:row.type==='slider'||row.type==='color'}));
      if(row.type==='slider')for(const [name,key]of [['min','propertyMin'],['max','propertyMax'],['step','propertyStep']])body.append(this.#field(name,this.#t[key],{value:row[name]??'',type:'number'}));
    }
    for(const name of ['value',...(row.type==='slider'?['min','max','step']:[])]){const input=$('user-property-'+name);this.#displayed.set(name,input.type==='checkbox'?input.checked:input.value);}
  }
  #renderOptions(){
    $('user-property-options').replaceChildren(...this.#options.map((option,index)=>{
      const row=element('fieldset'),legend=element('legend',String(index+1));row.dataset.optionIndex=index;
      row.append(legend,this.#field(`option-label-${index}`,this.#t.propertyOptionLabel,{value:option.label}),this.#field(`option-value-${index}`,this.#t.propertyOptionValue,{value:option.value}),this.#button(`remove-option-${index}`,this.#t.propertyRemoveOption));return row;
    }));
    this.#optionVisible=this.#options.map((_,index)=>({label:$(`user-property-option-label-${index}`).value,value:$(`user-property-option-value-${index}`).value}));
  }
  #readOptions(){return this.#options.map((raw,index)=>Object.fromEntries([...Object.entries(raw),...['label','value'].map(key=>{const value=$(`user-property-option-${key}-${index}`).value;return [key,value===this.#optionVisible[index][key]?raw[key]:value];})]));}
  #updateDefault(value=$('user-property-value')?.value,options=this.#options){
    const select=$('user-property-value');if(!select)return;
    select.replaceChildren(...options.map((item,index)=>{const option=element('option',`${item.label} · ${item.value}`);option.value=item.value;option.dataset.index=index;return option;}));
    select.value=value??'';
  }
  optionInput(){this.#updateDefault($('user-property-value').value,this.#readOptions());}
  optionChange(index){const value=$('user-property-value').value;this.#options=this.#readOptions();if(index===undefined)this.#options.push({label:'',value:''});else this.#options.splice(index,1);this.#renderOptions();this.#updateDefault(value);}
  values(){
    if(!this.form.reportValidity())throw new Error(this.#t.propertyInvalid);
    const type=$('user-property-type').value,input=$('user-property-value');
    if(type==='combo'&&input.selectedIndex<0)throw new Error(this.#t.propertyInvalid);
    // Native text controls normalize line endings. Preserve untouched exact JSON
    // values when another field changes, including unknown option metadata.
    const visible=type==='bool'?input.checked:input.value;
    const patch={text:$('user-property-text').value===this.#displayed.get('text')?this.#initial.text:$('user-property-text').value,
      value:visible===this.#displayed.get('value')?this.#typeInitial.value:type==='bool'?input.checked:type==='slider'?input.valueAsNumber:input.value};
    for(const name of ['order',...(type==='slider'?['min','max','step']:[])]){const input=$('user-property-'+name);patch[name]=input.value===''?undefined:input.valueAsNumber;}
    if(type==='combo')patch.options=this.#readOptions();
    return {name:this.#creating?$('user-property-key').value:this.#initial.name,declaration:{type,...Object.fromEntries(Object.entries(patch).filter(([,v])=>v!==undefined))},patch};
  }
  error(message){$('user-property-error').textContent=message??'';}
  inspection(error){this.list.replaceChildren();this.form.replaceChildren(element('p',this.#t.propertyInspect),element('pre',String(error.message)));for(const name of ['new','copy','delete'])$('user-property-'+name).disabled=true;}
  enabled(value){for(const control of this.panel.querySelectorAll('button,input,select,textarea')){if(!value){control.dataset.previousDisabled=String(control.disabled);control.disabled=true;}else if(control.dataset.previousDisabled!==undefined){control.disabled=control.dataset.previousDisabled==='true';delete control.dataset.previousDisabled;}}for(const b of this.dialog.querySelectorAll('button'))b.disabled=!value;}
  destroy(){this.dialog.remove();}
}
