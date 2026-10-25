import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,readFile,rm,access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const cli=fileURLToPath(new URL('./check-scene-scripts.mjs',import.meta.url));
test('offline command reports actual syntax/no-entry/read-only counts and never writes source',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'script-check-'));try{
  const marker=path.join(root,'must-not-exist.txt');
  const scene={objects:[{id:1,alpha:{value:1,script:`process.getBuiltinModule('node:fs').writeFileSync(${JSON.stringify(marker)},'executed'); export function update(value){return value;}`,scriptproperties:{script:'metadata not code !!!!'}}}]},file=path.join(root,'scene.json'),raw=JSON.stringify(scene);await writeFile(file,raw);
  const run=spawnSync(process.execPath,[cli,file],{encoding:'utf8',timeout:60000});assert.equal(run.status,0,run.stderr);const report=JSON.parse(run.stdout);assert.equal(report.checked,1);assert.equal(report.unvalidated,1);assert.equal(report.errors,0);assert.equal(await readFile(file,'utf8'),raw);await assert.rejects(access(marker),{code:'ENOENT'});
  scene.objects[0].alpha.script='export function update( {';await writeFile(file,JSON.stringify({title:'Source snapshot',entry:'scene.json',project:{type:'scene'},scene}));const bad=spawnSync(process.execPath,[cli,file],{encoding:'utf8',timeout:60000});assert.equal(bad.status,1);assert.equal(JSON.parse(bad.stdout).errors,1);
  scene.objects[0].alpha.script='let unused=2;';await writeFile(file,JSON.stringify(scene));const warning=spawnSync(process.execPath,[cli,file],{encoding:'utf8',timeout:60000});assert.equal(warning.status,0);assert.equal(JSON.parse(warning.stdout).warnings,1);
 }finally{await rm(root,{recursive:true});}
});
test('offline command rejects missing/extra files, malformed input and I/O failures',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'script-check-'));try{for(const args of [[],['missing.json'],['a','b']]){const result=spawnSync(process.execPath,[cli,...args],{encoding:'utf8',timeout:60000});assert.notEqual(result.status,0);assert(result.stderr.length>0);}const file=path.join(root,'bad.json');await writeFile(file,'not json');const result=spawnSync(process.execPath,[cli,file],{encoding:'utf8',timeout:60000});assert.notEqual(result.status,0);assert(result.stderr.length>0);}finally{await rm(root,{recursive:true});}
});

test('offline command distinguishes actual workspaces from raw scene metadata',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'script-check-'));try{
  const file=path.join(root,'input.json'),scene={objects:[{id:1,alpha:{value:1,script:'export function update(value){return value;}'}}],scene:{note:'custom metadata'}};
  const run=()=>spawnSync(process.execPath,[cli,file],{encoding:'utf8',timeout:60000});
  await writeFile(file,JSON.stringify(scene));assert.equal(JSON.parse(run().stdout).checked,1);
  for(const schema of [1,2]){await writeFile(file,JSON.stringify({schema,title:'Saved',sceneEntry:'scene.json',project:{type:'scene'},scene}));const result=run();assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).checked,1);}
  await writeFile(file,JSON.stringify({schema:3,title:'Future workspace',sceneEntry:'scene.json',project:{type:'scene'},scene}));const unsupported=run();assert.equal(unsupported.status,2);assert.match(unsupported.stderr,/schema/i);
  await writeFile(file,JSON.stringify({title:'Mixed',entry:'scene.json',project:{type:'scene'},scene,objects:[]}));const ambiguous=run();assert.equal(ambiguous.status,2);assert.match(ambiguous.stderr,/Ambiguous/);
 }finally{await rm(root,{recursive:true});}
});
