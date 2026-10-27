export const bindingDocument={title:'User property bindings',entry:'scene.json',project:{type:'scene',file:'scene.json',future:{keep:true},general:{properties:{
 enabled:{type:'bool',value:false,text:'Visible'},opacity:{type:'slider',value:0.5,min:0,max:1,text:'Opacity'},tint:{type:'color',value:'1 0 0',text:'Tint'},caption:{type:'textinput',value:'Authored 雪',text:'Caption'},fontSize:{type:'slider',value:40,min:1,max:96,text:'Font size'},
 mode:{type:'combo',value:'day',options:[{label:'Day',value:'day'},{label:'Night',value:'night'}],text:'Mode'},numeric:{type:'combo',value:'01',options:[{label:'One',value:'01'},{label:'Another one',value:'1'},{label:'Two',value:'2'}]},
 'é':{type:'textinput',value:'composed'},'e\u0301':{type:'textinput',value:'decomposed'},unknown:{type:'future-control',value:'keep'},
}}},scene:{future:{keep:['all']},general:{orthogonalprojection:{width:640,height:360},clearenabled:true,clearcolor:'0 0 0',cameraparallax:false},objects:[
 {id:1,name:'Direct target',solid:true,size:'100 100',origin:'120 180 0',color:'0 1 0',alpha:1,visible:true,future:{keep:1}},
 {id:2,name:'Conditional target',solid:true,size:'100 100',origin:'320 180 0',color:'0 1 0',alpha:1,visible:true},
 {id:3,name:'Text target',text:'Original\r\n雪',font:'Arial',pointsize:24,origin:'500 300 0',color:'1 1 1',alpha:1,visible:true},
 {id:4,name:'Script target',solid:true,size:'40 40',origin:'560 60 0',color:{value:'0 1 0',script:'// exact\r\nconst host=({}).constructor.constructor("return globalThis")();\r\nexport function update(v){const layer=thisScene.getLayer("Text target");host.__bindingTextProbe={text:layer.text,pointsize:layer.pointsize};return v;}',scriptproperties:{future:true},future:{keep:'🌙'}},alpha:1},
]}};
