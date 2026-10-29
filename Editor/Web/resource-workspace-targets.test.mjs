import test from 'node:test';
import assert from 'node:assert/strict';
import * as targets from './script-workspace-targets.mjs';
test('resource chooser retains literal identity, shared consumers and visible failures',()=>{
 assert.equal(typeof targets.resourceScriptTargets,'function');
 const record={path:'materials/雪.a.json',anchor:['passes',0,'constantshadervalues','a/b.c'],scriptPath:['passes',0,'constantshadervalues','a/b.c','script'],editable:true,registered:true,hasScript:true,source:'exact\r\n',valueKind:'vector4',consumers:[{layerId:1},{layerId:2}]};
 const failure={path:'broken.json',anchor:[],editable:false,reason:'Unreadable resource'};
 const result=targets.resourceScriptTargets({records:[record,failure]});
 assert.equal(result.length,2);assert.equal(result[0].resource,record);assert.equal(result[0].source,record.source);
 assert.equal(result[0].state.kind,'script');assert.equal(result[0].target,'resource:vector4');
 assert(result[0].label.includes(record.path));assert(result[0].label.includes('a/b.c'));
 assert.equal(result[0].consumers.length,2);assert.equal(result[1].state.reason,failure.reason);
 assert.equal(result[1].state.editable,false);
});
test('shared resource impact identifies every owning layer and literal consumer slot',()=>{
 const consumers=[{layerId:7,layerIndex:0,kind:'effect',effect:2,via:[{path:'effects/shared.雪.json',pass:1}]},{layerId:8,layerIndex:1,kind:'particle',child:3,via:[{path:'particles/root.json',child:3},{path:'particles/child.json',mesh:2,skin:0}]}];
 const labels=targets.resourceConsumerLabels(consumers,{objects:[{id:7,name:'Shared <effect>'},{id:8,name:'Child consumer',particle:'particles/root.json'}]});
 assert.equal(labels.length,2);assert.equal(labels[0].name,'Shared <effect>');assert.match(labels[0].location,/objects\[0\]\.effects\[2\]/);assert.match(labels[0].location,/effects\/shared\.雪\.json.*passes\[1\]/);
 assert.equal(labels[1].name,'Child consumer');assert.match(labels[1].location,/children\[3\]/);assert.match(labels[1].location,/meshes\[2\].*materials\[0\]/);
});
