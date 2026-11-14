// Independent authored expectations; never derive values from the catalog under test.
export const propertyDefaults = Object.freeze({enabled:true,amount:0.25,tint:'0 1 0',caption:'Initial caption',mode:'quiet','\u00e9':'composed-default','e\u0301':'decomposed-default'});
export const propertyChanges = Object.freeze({enabled:false,amount:0.75,tint:'1 0 0',caption:'',mode:'loud','\u00e9':'composed-live','e\u0301':'decomposed-live'});
export const propertyScript = `const host=({}).constructor.constructor('return globalThis')();
const probe=host.__propertyProbe??={top:0,init:0,apply:0,frames:0,values:{},history:[]};probe.top++;
export function init(value){probe.init++;probe.noOpener=host.opener===null;probe.noAuthoring=!['__dynamicWallpaperEditor','__editor','__editorConfiguration','__editorSession'].some(key=>key in host);return value;}
export function applyUserProperties(values){probe.apply++;for(const key of Object.keys(values)){const value=values[key];probe.values[key]=key==='tint'?[value.x,value.y,value.z]:value;}probe.history.push(host.JSON.parse(host.JSON.stringify(probe.values)));}
export function update(value){probe.frames++;probe.runtime=engine.runtime;return probe.values.enabled===false&&probe.values.amount===0.75&&probe.values.caption===''&&probe.values.mode==='loud'?new Vec3(1,0,0):new Vec3(0,1,0);}`;
export const propertiesDocument = {
 title:'Independent live property acceptance',entry:'scene.json',
 project:{title:'Independent live property acceptance',type:'scene',file:'scene.json',future:{preserve:['all','metadata']},
  general:{properties:{
   enabled:{type:'bool',value:true,text:'Enabled',order:0,future:{keep:true}},
   amount:{type:'slider',value:0.25,min:0,max:1,step:0.05,text:'Amount',order:1},
   tint:{type:'color',value:'0 1 0',text:'Tint',order:2},
   caption:{type:'textinput',value:'Initial caption',text:'Caption',order:3},
   mode:{type:'combo',value:'quiet',options:[{label:'Quiet',value:'quiet'},{label:'Loud',value:'loud'}],text:'Mode',order:4},
   '\u00e9':{type:'textinput',value:'composed-default',text:'Composed name'},
   'e\u0301':{type:'textinput',value:'decomposed-default',text:'Decomposed name'},
   future:{type:'future-control',value:'preserved',future:{keep:7}},
   conditional:{type:'bool',value:true,condition:'enabled == true'},
  }},preset:{enabled:{value:false},presetOnly:{value:'kept'}}},
 scene:{general:{orthogonalprojection:{width:640,height:360},clearenabled:true,clearcolor:'0 0 0',cameraparallax:false},objects:[
  {id:1,name:'Callback GPU oracle',solid:true,size:'160 100',origin:'320 180 0',color:{value:'0 1 0',script:propertyScript}},
  {id:2,name:'Direct bound tint GPU oracle',solid:true,size:'80 80',origin:'120 180 0',color:{value:'0 1 0',user:'tint'}},
 ]},
};
