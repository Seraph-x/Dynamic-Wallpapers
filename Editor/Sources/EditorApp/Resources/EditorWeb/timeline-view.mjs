import { ANIMATED_PROPERTIES,animationState,keyInterpolation } from './animation.mjs';
const $=id=>document.getElementById(id);
const propertyNames={origin:'position',scale:'scaleTrack',angles:'rotation',color:'colorTrack',alpha:'opacity'};
export const trackName=(property,channel,t)=>`${t[propertyNames[property]]}${ANIMATED_PROPERTIES[property].channels>1?' · '+(property==='color'?['R','G','B']:['X','Y','Z'])[channel]:''}`;
export const absoluteKey=(key,state,channel)=>key.value+(state.relative?state.base[channel]:0);
function curve(keys,options,range) {
  let low=Infinity,high=-Infinity;
  for(const key of keys)for(const value of [key.value,...[key.front,key.back].filter(handle=>handle?.enabled).map(handle=>key.value+(Number(handle.y)||0))]){
    low=Math.min(low,value);high=Math.max(high,value);
  }
  const y=value=>24-(value-low)/(high-low||1)*20;
  const x=frame=>(frame/Number(options.fps)-range.start)/(range.end-range.start)*1000;
  let path=`M ${x(keys[0].frame)} ${y(keys[0].value)}`;
  for(let index=1;index<keys.length;index++) {
    const a=keys[index-1],b=keys[index],third=(b.frame-a.frame)/3;
    const x1=a.frame+(a.front?.enabled?Math.min(Math.abs(Number(a.front.x)||0),1.5):1)*third;
    const x2=b.frame-(b.back?.enabled?Math.min(Math.abs(Number(b.back.x)||0),1.5):1)*third;
    const y1=a.front?.enabled?a.value+(Number(a.front.y)||0):a.value+(b.value-a.value)/3;
    const y2=b.back?.enabled?b.value+(Number(b.back.y)||0):b.value-(b.value-a.value)/3;
    path+=` C ${x(x1)} ${y(y1)} ${x(x2)} ${y(y2)} ${x(b.frame)} ${y(b.value)}`;
  }
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg'),line=document.createElementNS(svg.namespaceURI,'path');
  svg.setAttribute('viewBox','0 0 1000 28');svg.setAttribute('preserveAspectRatio','none');svg.setAttribute('aria-hidden','true');
  line.setAttribute('d',path);svg.append(line);return svg;
}
function rows({layer,selection,range,t,handlers}) {
  const container=$('timeline-tracks'),result=[];
  const focused=document.activeElement?.classList.contains('timeline-key')?{...document.activeElement.dataset}:null;
  for(const property of Object.keys(ANIMATED_PROPERTIES)) {
    const state=animationState(layer,property);if(state.kind!=='animation')continue;
    state.channels.forEach((keys,channel)=>{
      const row=document.createElement('div'),name=document.createElement('button'),lane=document.createElement('div');
      row.className='timeline-row';row.dataset.selected=String(selection.property===property&&selection.channel===channel);
      name.className='timeline-track-name';name.textContent=trackName(property,channel,t);name.title=name.textContent;
      name.setAttribute('aria-pressed',row.dataset.selected);name.onclick=()=>handlers.select(property,channel);
      lane.className='timeline-lane';lane.onclick=event=>{if(event.target===lane)handlers.scrub(range.start+(event.clientX-lane.getBoundingClientRect().left)/lane.getBoundingClientRect().width*(range.end-range.start));};
      lane.append(curve(keys,state.options,range));
      for(const key of keys) {
        const time=key.frame/Number(state.options.fps);if(time<range.start||time>range.end)continue;
        const button=document.createElement('button');button.type='button';button.className='timeline-key';
        Object.assign(button.dataset,{property,channel:String(channel),frame:String(key.frame)});
        button.style.left=`${(time-range.start)/(range.end-range.start)*100}%`;
        button.setAttribute('aria-label',`${name.textContent} · ${t.frame} ${key.frame} · ${t.value} ${absoluteKey(key,state,channel)}`);
        button.title=button.getAttribute('aria-label');button.setAttribute('aria-pressed',String(selection.property===property&&selection.channel===channel&&selection.frame===key.frame));
        button.onpointerdown=event=>handlers.drag(event,{property,channel,frame:key.frame},lane);
        button.onclick=event=>{if(event.detail===0)handlers.select(property,channel,key.frame);};lane.append(button);
      }
      const playhead=document.createElement('i');playhead.className='timeline-playhead';lane.append(playhead);
      row.append(name,lane);result.push(row);
    });
  }
  container.replaceChildren(...result);
  if(!result.length){const note=document.createElement('p');note.textContent=t.noAnimation;container.append(note);}
  if(focused)container.querySelector(`.timeline-key[data-property="${focused.property}"][data-channel="${focused.channel}"][data-frame="${focused.frame}"]`)?.focus({preventScroll:true});
}
export function renderTimeline({layer,selection,range,clipboard,draftKey,draftSettings,t,handlers}) {
  const state=layer?animationState(layer,selection.property):{kind:'constant'};
  $('timeline-layer').textContent=String(layer?.name??'');$('timeline-property').disabled=!layer;$('timeline-property').value=selection.property;
  $('timeline-create').disabled=!layer;$('timeline-create').hidden=state.kind==='animation';
  $('timeline-create').textContent=state.kind==='constant'?t.addTrack:t.replaceBinding;
  $('timeline-settings').hidden=state.kind!=='animation';
  const key=state.channels?.[selection.channel]?.find(key=>key.frame===selection.frame);
  $('timeline-key-editor').hidden=!key;
  for(const id of ['timeline-add-key','timeline-remove'])$(id).disabled=state.kind!=='animation';
  for(const id of ['timeline-delete-key','timeline-copy-key'])$(id).disabled=!key;
  $('timeline-paste-key').disabled=!clipboard||state.kind!=='animation';
  $('timeline-track-note').textContent=state.reason??(state.relative?t.relativeTrack:'');
  if(state.kind==='animation'&&!draftSettings) {
    $('timeline-fps').value=state.options.fps;$('timeline-length').value=state.options.length;$('timeline-mode').value=state.options.mode;
  }
  if(key&&!draftKey) {
    $('timeline-key-frame').value=key.frame;$('timeline-key-frame').max=state.options.length;
    $('timeline-key-value').value=absoluteKey(key,state,selection.channel);$('timeline-interpolation').value=keyInterpolation(key);
  }
  $('timeline-key-label').textContent=key?trackName(selection.property,selection.channel,t):'';
  const ruler=document.querySelector('.timeline-ruler');ruler.replaceChildren(...Array.from({length:6},(_,index)=>{
    const tick=document.createElement('span');tick.textContent=`${Number((range.start+(range.end-range.start)*index/5).toFixed(3))} s`;return tick;
  }));
  if(layer)rows({layer,selection,range,t,handlers});else $('timeline-tracks').replaceChildren();
}
export function renderTime(time,range,fps,sampled,syncSlider=true) {
  if(document.activeElement!==$('timeline-time'))$('timeline-time').value=Number(time.toFixed(4));
  $('timeline-time-frame').textContent=String(Number((time*fps).toFixed(3)));
  const scrub=$('timeline-scrub');
  if(syncSlider){scrub.min=range.start;scrub.max=range.end;scrub.step=1/fps;scrub.value=time;}
  scrub.setAttribute('aria-valuetext',`${Number((syncSlider?time:Number(scrub.value)).toFixed(3))} s`);
  $('timeline-current-value').textContent=Number.isFinite(sampled)?String(Number(sampled.toFixed(4))):'—';
  for(const cursor of document.querySelectorAll('.timeline-playhead')) {
    cursor.hidden=time<range.start||time>range.end;cursor.style.left=`${(time-range.start)/(range.end-range.start)*100}%`;
  }
}
