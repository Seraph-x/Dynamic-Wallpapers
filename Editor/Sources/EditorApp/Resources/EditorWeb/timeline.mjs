import { ANIMATED_PROPERTIES,animationState,keyInterpolation } from './animation.mjs';
import { TimelineClock } from './timeline-clock.mjs';
import { renderTimeline,renderTime,absoluteKey } from './timeline-view.mjs';
const $=id=>document.getElementById(id);

export class Timeline {
  #editor;#t;#edit;#error;#reset;#clock;#layer;#selection={property:'origin',channel:0};#clipboard;#beforeEdit;
  #keyDraft=false;#settingsDraft=false;#keyCommit;#settingsCommit;#pending=new Set();#drag;#frame;#closed=false;#rate=30;
  #operations=Promise.resolve();#keyRevision=0;#settingsRevision=0;
  #keyboardTargets=new WeakMap();
  #scrubRequests=0;#scrubPointer=false;
  constructor({editor,t,edit,onError,onResetInput,beforeEdit=async()=>{}}) {
    this.#beforeEdit=beforeEdit;
    this.#editor=editor;this.#t=t;this.#edit=edit;this.#error=onError;this.#reset=onResetInput;this.#clock=new TimelineClock(editor);
    const bind=(id,event,operation)=>$(id).addEventListener(event,value=>{void this.#run(()=>operation(value));});
    bind('timeline-toggle','click',()=>this.#toggle());bind('timeline-close','click',()=>this.#toggle());
    $('timeline-property').addEventListener('change',event=>{
      const property=event.target.value;
      void this.#run(async()=>{await this.#prepare();this.#selection={property,channel:0};this.#render();});
    });
    bind('timeline-create','click',()=>this.#create());
    bind('timeline-previous','click',()=>this.#clock.step(-1,this.#fps()));bind('timeline-next','click',()=>this.#clock.step(1,this.#fps()));
    $('timeline-time').addEventListener('change',event=>{const time=event.target.valueAsNumber;void this.#run(()=>this.#clock.seek(time));});
    $('timeline-scrub').addEventListener('input',event=>{
      const time=Number(event.target.value);this.#editor.setPlaying(false);this.#scrubRequests++;
      void this.#run(()=>this.#clock.seek(time)).then(()=>this.#scrubRequests--,()=>this.#scrubRequests--);
    });
    $('timeline-scrub').addEventListener('pointerdown',()=>{this.#scrubPointer=true;});
    for(const event of ['pointerup','pointercancel'])window.addEventListener(event,()=>{this.#scrubPointer=false;});
    for(const id of ['timeline-start','timeline-end','timeline-loop'])bind(id,'change',()=>{
      this.#clock.range({start:$('timeline-start').valueAsNumber,end:$('timeline-end').valueAsNumber,loop:$('timeline-loop').checked});this.#render();
    });
    $('timeline-settings').addEventListener('input',()=>{this.#settingsDraft=true;this.#settingsRevision++;});
    $('timeline-key-editor').addEventListener('input',()=>{this.#keyDraft=true;this.#keyRevision++;});
    for(const id of ['timeline-settings','timeline-key-editor'])$(id).addEventListener('submit',event=>{event.preventDefault();void this.#run(()=>this.#prepare());});
    bind('timeline-revert','click',()=>{this.#keyDraft=false;this.#settingsDraft=false;this.#reset();this.#render();});
    bind('timeline-settings-revert','click',()=>{this.#settingsDraft=false;this.#reset();this.#render();});
    bind('timeline-add-key','click',async()=>{
      await this.#prepare();this.#editor.setPlaying(false);const state=this.#state(),selection=this.#selection,target=this.#context(),frame=this.#atFrame(this.#clock.time,state);
      await this.#clock.seek(frame/Number(state.options.fps));
      const sample=this.#editor.controls.getLayerProps(target.id)?.[target.property],value=Array.isArray(sample)?sample[target.channel]:sample;
      await this.#change({type:'set-key',channel:target.channel,frame,value},target);if(this.#selection===selection)selection.frame=frame;this.#render();
    });
    bind('timeline-delete-key','click',async()=>{await this.#prepare();const selection=this.#selection;await this.#change({type:'delete-key',channel:selection.channel,frame:selection.frame});if(this.#selection===selection)selection.frame=undefined;this.#render();});
    bind('timeline-copy-key','click',()=>this.#copy());bind('timeline-paste-key','click',()=>this.#paste());
    bind('timeline-remove','click',async()=>{await this.#prepare();const selection=this.#selection;await this.#change({type:'remove',value:this.#current()});if(this.#selection===selection)selection.frame=undefined;this.#render();});
    bind('timeline','pointerup',()=>this.#finishDrag());
    bind('timeline','pointercancel',()=>{this.#drag=undefined;this.#render();});
    $('timeline').addEventListener('pointermove',event=>this.#moveDrag(event));
    $('timeline').addEventListener('keydown',event=>this.#keyboard(event));
    const dialog=$('timeline-confirm');
    bind('timeline-confirm-cancel','click',()=>dialog.close());
    bind('timeline-confirm-replace','click',async()=>{dialog.close();await this.#createTrack(true);});
    const tick=()=>{
      if(this.#closed)return;
      void this.#clock.tick().catch(error=>{editor.setPlaying(false);onError(error);});
      if(!$('timeline').hidden&&editor.controls)renderTime(this.#clock.time,this.#clock.rangeValue,this.#fps(),this.#sample(),!this.#scrubPointer&&!this.#scrubRequests);
      this.#frame=requestAnimationFrame(tick);
    };tick();
  }
  get hasDraft(){return this.#keyDraft||this.#settingsDraft||Boolean(this.#drag);}
  #run(operation) {
    const promise=this.#operations.then(operation);this.#pending.add(promise);
    this.#operations=promise.catch(()=>{}); // Callers and the diagnostic handler retain the actual rejection.
    void promise.catch(this.#error).finally(()=>this.#pending.delete(promise));return promise;
  }
  #state(){return this.#layer?animationState(this.#layer,this.#selection.property):{kind:'constant'};}
  #fps(){return this.#rate;}
  #current(){return this.#layer?this.#editor.controls?.getLayerProps(this.#layer.id)?.[this.#selection.property]:undefined;}
  #sample(){const value=this.#current();return Array.isArray(value)?value[this.#selection.channel]:value;}
  #atFrame(time,state=this.#state()) {
    const fps=Number(state.options?.fps??30),frame=time*fps;
    return $('timeline-snap').checked?Math.round(frame):frame;
  }
  #context(){return {id:this.#layer?.id,property:this.#selection.property,channel:this.#selection.channel};}
  async #change(edit,target=this.#context()){
    if(target.id===undefined)throw new Error('Select a layer first');
    const document=this.#editor.document;await this.#beforeEdit();if(this.#editor.document!==document)throw new Error('Timeline document changed while preparing the edit');
    this.#editor.setPlaying(false);await this.#edit(target.id,target.property,edit);this.#reset();
  }
  #toggle(){const panel=$('timeline');panel.hidden=!panel.hidden;$('timeline-toggle').setAttribute('aria-expanded',String(!panel.hidden));if(!panel.hidden)this.#render();}
  update(document,selected) {
    const layer=document.snapshot().scene.objects?.find(layer=>layer.id===selected);
    if(this.#layer?.id!==layer?.id){
      const property=Object.keys(ANIMATED_PROPERTIES).find(property=>layer&&animationState(layer,property).kind==='animation')??'origin';
      this.#selection={property,channel:0};this.#keyDraft=false;this.#settingsDraft=false;
    }
    this.#layer=layer;this.#render();
  }
  #render() {
    this.#rate=Number(this.#state().options?.fps??30);
    if($('timeline').hidden)return;
    renderTimeline({layer:this.#layer,selection:this.#selection,range:this.#clock.rangeValue,clipboard:this.#clipboard,
      draftKey:this.#keyDraft,draftSettings:this.#settingsDraft,t:this.#t,handlers:{
        select:(...args)=>void this.#run(()=>this.#select(...args)),scrub:time=>void this.#run(()=>this.#clock.seek(time)),
        drag:(...args)=>{try{this.#beginDrag(...args);}catch(error){this.#error(error);}},
      }});
  }
  async #select(property,channel,frame) {
    await this.#prepare();this.#selection={property,channel,frame};
    if(frame!==undefined)await this.#clock.seek(frame/Number(this.#state().options.fps));this.#render();
  }
  async #create(){await this.#prepare();if(this.#state().kind==='constant')await this.#createTrack(false);else $('timeline-confirm').showModal();}
  async #createTrack(replace) {
    const fps=30,length=this.#clock.rangeValue.end*fps,selection=this.#selection;
    await this.#change({type:'create',fps,length,mode:'loop',replace,value:this.#current()});if(this.#selection===selection)selection.frame=0;this.#render();
  }
  async #commitKey() {
    this.#validateForm('timeline-key-editor');
    const selection=this.#selection,revision=this.#keyRevision,old=selection.frame,frame=$('timeline-key-frame').valueAsNumber,value=$('timeline-key-value').valueAsNumber;
    const mode=$('timeline-interpolation').value,channel=this.#selection.channel;
    const id=this.#layer.id,property=this.#selection.property;
    this.#editor.setPlaying(false);
    const document=this.#editor.document;await this.#beforeEdit();if(this.#editor.document!==document)throw new Error('Timeline document changed while preparing the edit');
    await this.#editor.change(doc=>doc.transaction(draft=>{
      if(frame!==old)draft.animate(id,property,{type:'move-key',channel,from:old,frame});
      draft.animate(id,property,{type:'set-key',channel,frame,value,...(mode==='custom'?{}:{interpolation:mode})});
    }));
    if(this.#selection===selection){selection.frame=frame;this.#keyDraft=this.#keyRevision!==revision;}
    this.#reset();this.#render();
  }
  async #commitSettings() {
    this.#validateForm('timeline-settings');
    const selection=this.#selection,revision=this.#settingsRevision;
    await this.#change({type:'settings',fps:$('timeline-fps').valueAsNumber,length:$('timeline-length').valueAsNumber,mode:$('timeline-mode').value});
    if(this.#selection===selection)this.#settingsDraft=this.#settingsRevision!==revision;this.#render();
  }
  #validateForm(id) {
    const form=$(id);if(form.checkValidity())return;
    if(!document.body.inert)form.reportValidity();
    throw new Error(form.querySelector('input:invalid,select:invalid')?.validationMessage??'Invalid animation input');
  }
  async #prepare() {
    while(this.#keyDraft||this.#settingsDraft){
      if(this.#keyDraft){this.#keyCommit??=this.#commitKey().finally(()=>{this.#keyCommit=undefined;});await this.#keyCommit;}
      if(this.#settingsDraft){this.#settingsCommit??=this.#commitSettings().finally(()=>{this.#settingsCommit=undefined;});await this.#settingsCommit;}
    }
  }
  async #copy(){await this.#prepare();const state=this.#state(),key=state.channels?.[this.#selection.channel]?.find(key=>key.frame===this.#selection.frame);if(!key)throw new Error(this.#t.chooseKey);this.#clipboard={...structuredClone(key),value:absoluteKey(key,state,this.#selection.channel)};this.#render();}
  async #paste(){await this.#prepare();const selection=this.#selection,frame=this.#atFrame(this.#clock.time);await this.#change({type:'paste-key',channel:selection.channel,frame,key:this.#clipboard});if(this.#selection===selection)selection.frame=frame;this.#render();}
  #beginDrag(event,selection,lane) {
    if(event.button!==0||this.#editor.frozen)return;
    if(this.#keyDraft||this.#settingsDraft)throw new Error('Apply or revert the key/track inputs before dragging');
    event.preventDefault();this.#editor.setPlaying(false);this.#selection={...selection};
    this.#drag={...selection,id:this.#layer.id,selection:this.#selection,button:event.currentTarget,bounds:lane.getBoundingClientRect(),pointer:event.pointerId,target:selection.frame};
    $('timeline').setPointerCapture(event.pointerId);
    // Selection must update before the asynchronous seek completes; otherwise a
    // fast inspector edit would still contain the previously selected key.
    this.#render();this.#drag.button=document.querySelector(`.timeline-key[data-property="${selection.property}"][data-channel="${selection.channel}"][data-frame="${selection.frame}"]`);
    this.#focusKey();
  }
  #moveDrag(event) {
    if(!this.#drag||event.pointerId!==this.#drag.pointer)return;
    const {start,end}=this.#clock.rangeValue,{bounds}=this.#drag,state=this.#state();
    const time=start+(event.clientX-bounds.left)/bounds.width*(end-start);
    this.#drag.target=Math.max(0,Math.min(Number(state.options.length),this.#atFrame(Math.max(0,time),state)));
    this.#drag.button.style.left=`${(this.#drag.target/this.#fps()-start)/(end-start)*100}%`;
  }
  async #finishDrag() {
    const drag=this.#drag;if(!drag)return;this.#drag=undefined;
    if($('timeline').hasPointerCapture(drag.pointer))$('timeline').releasePointerCapture(drag.pointer);
    try {
      if(drag.target!==drag.frame)await this.#change({type:'move-key',channel:drag.channel,from:drag.frame,frame:drag.target},drag);
      if(this.#selection===drag.selection){this.#selection.frame=drag.target;await this.#clock.seek(drag.target/Number(this.#state().options.fps));}
    } finally { this.#render();this.#focusKey(); }
  }
  #focusKey(){document.querySelector(`.timeline-key[data-property="${this.#selection.property}"][data-channel="${this.#selection.channel}"][data-frame="${this.#selection.frame}"]`)?.focus({preventScroll:true});}
  #keyboard(event) {
    if(/INPUT|TEXTAREA|SELECT/.test(event.target.tagName)||this.#editor.frozen)return;
    const key=event.target.closest('.timeline-key');
    if((event.metaKey||event.ctrlKey)&&['c','v'].includes(event.key.toLowerCase())) {
      event.preventDefault();void this.#run(()=>event.key.toLowerCase()==='c'?this.#copy():this.#paste());return;
    }
    if(!['ArrowLeft','ArrowRight','Delete','Backspace'].includes(event.key))return;
    let target;
    if(key){
      target=this.#keyboardTargets.get(key);
      if(!target){
        const {property,channel,frame}=key.dataset,selection=this.#selection;
        target=selection.property===property&&selection.channel===Number(channel)&&selection.frame===Number(frame)
          ?selection:{property,channel:Number(channel),frame:Number(frame)};
        target.id=this.#layer.id;this.#keyboardTargets.set(key,target);
      }
    }
    event.preventDefault();void this.#run(async()=>{
      await this.#prepare();const amount=(event.key==='ArrowLeft'?-1:1)*(event.shiftKey?10:1);
      if(key){
        this.#selection=target;
        if(['Delete','Backspace'].includes(event.key)){await this.#change({type:'delete-key',channel:target.channel,frame:target.frame},target);target.frame=undefined;}
        else {const from=target.frame,frame=from+amount;await this.#change({type:'move-key',channel:target.channel,from,frame},target);target.frame=frame;}
        this.#render();this.#focusKey();
      } else if(event.key.startsWith('Arrow'))await this.#clock.step(amount,this.#fps());
    });
  }
  async flush(){await this.#finishDrag();await Promise.all([...this.#pending]);await this.#prepare();}
  destroy(){this.#closed=true;cancelAnimationFrame(this.#frame);}
}
