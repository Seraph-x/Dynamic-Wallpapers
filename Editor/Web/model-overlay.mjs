export function drawWeightMap(canvas,mesh,bone,selected) {
  const context=canvas.getContext('2d');context.clearRect(0,0,canvas.width,canvas.height);
  if(!mesh?.vertexCount)return undefined;
  const xs=[],ys=[];for(let i=0;i<mesh.vertexCount;i++){xs.push(mesh.positions[i*3]);ys.push(mesh.positions[i*3+1]);}
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity;
  for(let i=0;i<xs.length;i++){minX=Math.min(minX,xs[i]);maxX=Math.max(maxX,xs[i]);minY=Math.min(minY,ys[i]);maxY=Math.max(maxY,ys[i]);}
  const scale=Math.min((canvas.width-24)/(maxX-minX||1),(canvas.height-24)/(maxY-minY||1));
  const points=xs.map((x,i)=>[(x-(minX+maxX)/2)*scale+canvas.width/2,canvas.height/2-(ys[i]-(minY+maxY)/2)*scale]);
  context.strokeStyle='#797a7866';context.lineWidth=1;context.beginPath();
  for(let i=0;i<mesh.indices.length;i+=3){const [a,b,c]=Array.from(mesh.indices.subarray(i,i+3),v=>points[v]);context.moveTo(...a);context.lineTo(...b);context.lineTo(...c);context.closePath();}context.stroke();
  for(let i=0;i<points.length;i++){
    let weight=0;for(let k=0;k<4;k++)if(mesh.joints[i*4+k]===bone)weight+=mesh.weights[i*4+k];
    context.fillStyle=`rgb(${Math.round(70+185*Math.min(1,weight))},${Math.round(125-50*Math.min(1,weight))},${Math.round(175-120*Math.min(1,weight))})`;
    context.beginPath();context.arc(...points[i],3,0,Math.PI*2);context.fill();
  }
  context.strokeStyle='#faf0d6';context.lineWidth=2;context.beginPath();context.arc(...points[selected],6,0,Math.PI*2);context.stroke();return points;
}
export class ModelBoneOverlay {
  #svg;#editor;#state;#select;#frame;#closed=false;#nodes=[];
  constructor({svg,editor,state,onSelect}) {
    this.#svg=svg;this.#editor=editor;this.#state=state;this.#select=onSelect;
    const tick=()=>{if(this.#closed)return;this.#draw();this.#frame=requestAnimationFrame(tick);};tick();
  }
  #draw() {
    const state=this.#state(),svg=this.#svg;svg.toggleAttribute('hidden',!state.visible);
    if(!state.visible){if(svg.childNodes.length)svg.replaceChildren();this.#nodes=[];return;}
    const points=this.#editor.controls?.getBonePoints(state.id)??[],box=svg.getBoundingClientRect();
    svg.setAttribute('viewBox',`0 0 ${box.width} ${box.height}`);
    const make=(tag,attributes)=>{const node=document.createElementNS('http://www.w3.org/2000/svg',tag);for(const [name,value] of Object.entries(attributes))node.setAttribute(name,String(value));return node;};
    while(this.#nodes.length>points.length){const value=this.#nodes.pop();value.line.remove();value.group.remove();}
    points.forEach((bone,i)=>{
      if(!this.#nodes[i]){
        const group=make('g',{role:'button',tabindex:0,'data-overlay-bone':i}),circle=make('circle',{}),line=make('line',{});group.append(circle);
        group.addEventListener('click',()=>this.#select(i));group.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();this.#select(i);}});
        this.#nodes[i]={group,circle,line};svg.append(line,group);
      }
      const {group,circle,line}=this.#nodes[i],parent=points[bone.parent]?.screen;
      group.toggleAttribute('hidden',!bone.screen);line.toggleAttribute('hidden',!bone.screen||!parent);group.setAttribute('aria-label',bone.name);group.setAttribute('aria-pressed',String(state.bone===i));
      if(!bone.screen)return;
      circle.setAttribute('cx',bone.screen[0]);circle.setAttribute('cy',bone.screen[1]);circle.setAttribute('r',state.bone===i?6:4);
      if(parent)for(const [key,value] of Object.entries({x1:parent[0],y1:parent[1],x2:bone.screen[0],y2:bone.screen[1]}))line.setAttribute(key,value);
    });
  }
  destroy(){this.#closed=true;cancelAnimationFrame(this.#frame);this.#svg.replaceChildren();}
}
