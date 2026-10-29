import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {readEditorPackage} from '../Editor/Web/package-archive.mjs';

const [fixture,output,...extra]=process.argv.slice(2);
if(!fixture||!output||extra.length)throw new Error('usage: node scripts/verify-editor-resource-script-export.mjs FIXTURE NATIVE_OUTPUT');
const target=JSON.parse(await readFile(path.join(fixture,'target.json'))),original=JSON.parse(await readFile(path.join(fixture,'source-document.json')));
const expected=await readFile(path.join(fixture,'expected-resource.bin'));
assert.equal(createHash('sha256').update(expected).digest('hex'),target.expectedDigest);
async function inventory(directory,prefix=''){
 const files=[];
 for(const entry of await readdir(path.join(directory,prefix),{withFileTypes:true})){
  const name=prefix?prefix+'/'+entry.name:entry.name;
  if(entry.isDirectory())files.push(...await inventory(directory,name));
  else {assert(entry.isFile(),'Acceptance inventory contains an unsupported file type');files.push(name);}
 }
 return files.sort();
}
const sourceRoot=path.join(fixture,'Source'),files=await inventory(sourceRoot);
assert.deepEqual(await inventory(path.join(output,'Package')),['project.json','scene.pkg'],'Native package export inventory changed');
for(const [directory,entry] of [['Loose','scene.json'],['Package','scene.pkg']]){
 assert.deepEqual(JSON.parse(await readFile(path.join(output,directory,'project.json'))),{...original.project,file:entry},`Native ${directory} project metadata changed`);
}
const pkg=readEditorPackage(await readFile(path.join(output,'Package/scene.pkg')));
assert.deepEqual([...pkg.paths].sort(),files.filter(name=>name!=='project.json'),'Native PKG omitted or added a source resource');
assert.deepEqual(await inventory(path.join(output,'Loose')),files,'Native loose export inventory changed');
for(const name of files){
 if(name==='scene.json'){
  assert.deepEqual(JSON.parse(new TextDecoder().decode(pkg.read(name))),original.scene);
  assert.deepEqual(JSON.parse(await readFile(path.join(output,'Loose',name))),original.scene);
 }else if(name!=='project.json'){
  const bytes=name===target.path?expected:await readFile(path.join(sourceRoot,name));
  assert.deepEqual(Buffer.from(pkg.read(name)),bytes,`Native PKG changed unrelated bytes in ${name}`);
  assert.deepEqual(await readFile(path.join(output,'Loose',name)),bytes,`Native loose export changed unrelated bytes in ${name}`);
 }
}
console.log(`Native resource ${target.sink}: exact loose/PKG inventory and all ${files.length-2} resource byte sequences verified`);
