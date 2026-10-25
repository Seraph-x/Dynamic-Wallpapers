export class WeightBrushController {
  #canvas;#keys;#options;#stroke;#task=Promise.resolve();#abort=new AbortController();#closed=false;
  constructor(options) {
    this.#options=options;this.#canvas=options.canvas;this.#keys=options.keys??document;
    const listen=(target,event,fn)=>target.addEventListener(event,fn,{signal:this.#abort.signal});
    listen(this.#canvas,'pointerdown',event=>this.#down(event));
    listen(this.#canvas,'pointermove',event=>this.#move(event));
    listen(this.#canvas,'pointerup',event=>this.#up(event));
    listen(this.#canvas,'pointercancel',event=>{if(this.#stroke?.id===event.pointerId)this.cancel();});
    listen(this.#canvas,'lostpointercapture',event=>{if(this.#stroke?.id===event.pointerId&&!this.#stroke.up)this.cancel();});
    listen(this.#canvas,'pointerleave',()=>{if(!this.#stroke)this.#options.onHover(undefined);});
    listen(this.#keys,'keydown',event=>{if(event.key==='Escape'&&this.blocksEditing){event.preventDefault();this.cancel();}});
  }
  get busy(){return Boolean(this.#stroke);}
  get blocksEditing(){return this.#stroke&&!this.#stroke.up&&this.#stroke.phase!=='committing';}
  assertIdle(){if(this.blocksEditing)throw this.#stroke.error;}
  settled(){return this.#task;}
  #point(event){const box=this.#canvas.getBoundingClientRect();if(!box.width||!box.height)throw new Error('Weight map is not visible');return [(event.clientX-box.left)*this.#canvas.width/box.width,(event.clientY-box.top)*this.#canvas.height/box.height];}
  #down(event) {
    if(this.#closed||this.busy||!this.#options.enabled()||!event.isPrimary||event.button!==0)return;
    event.preventDefault();this.#canvas.focus();
    const error=new Error('Finish or cancel the weight brush stroke before changing the scene');error.code='EDITOR_WEIGHT_STROKE_PENDING';
    const stroke={id:event.pointerId,phase:'preparing',points:[this.#point(event)],error};this.#stroke=stroke;this.#canvas.setPointerCapture(stroke.id);this.#options.onState();
    let prepared;try{prepared=this.#options.prepare();}catch(error){this.#fail(stroke,error);return;}
    this.#task=Promise.resolve(prepared).then(async context=>{
      stroke.context=context;
      if(stroke.cancelled||this.#closed){context.cancel();return;}
      stroke.phase='painting';for(const p of stroke.points)context.move(p);stroke.points=[];
      if(stroke.up)await this.#commit(stroke);
    }).catch(error=>this.#fail(stroke,error));
  }
  #move(event) {
    const stroke=this.#stroke;
    if(!stroke){if(this.#options.enabled())this.#options.onHover(this.#point(event));return;}
    if(event.pointerId!==stroke.id||stroke.up||stroke.phase==='committing')return;
    try{const p=this.#point(event);if(stroke.context)stroke.context.move(p);else stroke.points.push(p);}catch(error){this.#fail(stroke,error);}
  }
  #up(event) {
    const stroke=this.#stroke;if(!stroke||event.pointerId!==stroke.id||stroke.up||stroke.phase==='committing')return;
    try{const p=this.#point(event);stroke.up=true;if(stroke.context){stroke.context.move(p);this.#task=this.#commit(stroke).catch(error=>this.#fail(stroke,error));}else stroke.points.push(p);}
    catch(error){this.#fail(stroke,error);}
  }
  async #commit(stroke) {
    stroke.phase='committing';this.#release(stroke);this.#options.onState();
    await stroke.context.commit();if(this.#stroke===stroke)this.#stroke=undefined;this.#options.onState();this.#options.onFinish(stroke.error);
  }
  #release(stroke){if(stroke.released)return;stroke.released=true;if(this.#canvas.hasPointerCapture(stroke.id))this.#canvas.releasePointerCapture(stroke.id);}
  #fail(stroke,error){
    stroke.cancelled=true;if(this.#stroke===stroke)this.#stroke=undefined;this.#release(stroke);stroke.context?.cancel();this.#options.onState();this.#options.onFinish(stroke.error);this.#options.onError(error);
  }
  cancel() {
    const stroke=this.#stroke;if(!stroke||stroke.phase==='committing')return;
    stroke.cancelled=true;this.#stroke=undefined;this.#release(stroke);stroke.context?.cancel();this.#options.onState();this.#options.onFinish(stroke.error);
  }
  destroy(){this.#closed=true;this.cancel();this.#abort.abort();}
}
