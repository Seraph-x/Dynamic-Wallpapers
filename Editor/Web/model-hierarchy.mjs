import { inspectModel,rewriteSkeleton } from './model.mjs';
import { restMatrix } from './model-math.mjs';

const valid=(value,count)=>Number.isInteger(value)&&value>=0&&value<count;
export function editModelHierarchy(bytes,edit) {
  const model=inspectModel(bytes),count=model.bones.length;
  const nodes=model.bones.map((bone,source)=>({source,parent:bone.parent}));
  const parent=value=>{if(value!==-1&&!valid(value,count))throw new Error('Invalid parent bone');return value;};
  let removed;
  switch(edit.type){
    case 'rename':
      if(!valid(edit.bone,count))throw new Error('Invalid bone');nodes[edit.bone].name=edit.name;break;
    case 'reparent':
      if(!valid(edit.bone,count))throw new Error('Invalid bone');nodes[edit.bone].parent=parent(edit.parent);break;
    case 'create':nodes.push({source:null,parent:parent(edit.parent),name:edit.name,matrix:restMatrix(edit.pose)});break;
    case 'delete':
      if(!valid(edit.bone,count) || count===1)throw new Error('Cannot delete this bone');
      if(edit.replacement!==undefined && (!valid(edit.replacement,count)||edit.replacement===edit.bone))throw new Error('Invalid replacement bone');
      removed=edit.bone;
      nodes.forEach(node=>{if(node.parent===removed)node.parent=model.bones[removed].parent;});break;
    default:throw new Error('Unsupported hierarchy command');
  }
  const ordered=[],visiting=new Set(),visited=new Set();
  function visit(id) {
    if(id===removed)return;
    if(visited.has(id))return;
    if(visiting.has(id))throw new Error('Bone hierarchy cycle');visiting.add(id);
    const node=nodes[id];if(!node)throw new Error('Invalid hierarchy parent');
    if(node.parent!==-1)visit(node.parent);
    visiting.delete(id);visited.add(id);ordered.push(id);
  }
  nodes.forEach((_,id)=>visit(id));const destination=new Map(ordered.map((id,i)=>[id,i]));
  const bones=ordered.map(id=>({...nodes[id],parent:nodes[id].parent===-1?-1:destination.get(nodes[id].parent)}));
  const replacements=removed!==undefined&&edit.replacement!==undefined?{[removed]:destination.get(edit.replacement)}:{};
  return rewriteSkeleton(bytes,{bones,replacements,boneLimit:edit.boneLimit});
}
