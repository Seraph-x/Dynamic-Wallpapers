#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { checkSceneScriptSources } from '../Sources/EditorApp/Resources/EditorWeb/script-api.mjs';
function sceneInput(value){
 const object=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
 const snapshot=object(value)&&object(value.project)&&value.project.type==='scene'&&typeof value.title==='string'&&(typeof value.entry==='string'||typeof value.sceneEntry==='string');
 if(snapshot){
  if(Object.hasOwn(value,'objects')||Object.hasOwn(value,'general'))throw new Error('Ambiguous scene and workspace input');
  if(typeof value.entry!=='string'&&![1,2].includes(value.schema))throw new Error('Unsupported workspace schema');
  return value.scene;
 }
 return value;
}
try{
 const args=process.argv.slice(2);if(args.length!==1)throw new Error('Usage: node Editor/Web/check-scene-scripts.mjs <scene.json or workspace.json>');
 const value=JSON.parse(await readFile(args[0],'utf8')),report=checkSceneScriptSources(sceneInput(value));
 process.stdout.write(JSON.stringify(report,null,2)+'\n');process.exitCode=report.ok?0:1;
}catch(error){process.stderr.write(`SceneScript check: ${error.message}\n`);process.exitCode=2;}
