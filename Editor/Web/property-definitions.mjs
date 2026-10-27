import { createPropertyCatalog } from './property-catalog.mjs';

const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const fields=new Set(['text','value','order','min','max','step','options']);
const requireValue=(condition,message)=>{if(!condition)throw new Error(message);};

function availableName(project,name) {
  requireValue(typeof name==='string'&&name.length>0,'A property identifier is required');
  requireValue(name!=='__proto__','This property identifier is unsupported by the renderer');
  requireValue(!Object.hasOwn(project.general?.properties??{},name)&&!Object.hasOwn(project.preset??{},name),'Property identifier already exists');
}
function editableRow(project,name) {
  const row=createPropertyCatalog(project).find(row=>row.name===name);
  requireValue(row!==undefined,'Property does not exist');
  requireValue(!row.readOnlyReason,`Read-only property: ${row.readOnlyReason}`);
  return row;
}
function validate(project,name) {
  const row=createPropertyCatalog(project).find(row=>row.name===name);
  requireValue(row&&!row.readOnlyReason,`Invalid property declaration: ${row?.readOnlyReason??'missing'}`);
}

export function editPropertyDefinition(project,edit) {
  createPropertyCatalog(project); // Expose malformed owners before creating metadata.
  requireValue(object(edit),'Invalid property definition edit');
  const next=structuredClone(project);
  if(edit.type==='create'||edit.type==='copy') {
    const name=edit.type==='create'?edit.name:edit.newName;
    availableName(next,name);
    const declaration=edit.type==='create'?edit.declaration:editableRow(next,edit.name).raw;
    requireValue(object(declaration),'Invalid property declaration');
    next.general??={};next.general.properties??={};
    Object.defineProperty(next.general.properties,name,{value:structuredClone(declaration),enumerable:true,writable:true,configurable:true});
    validate(next,name);
  } else if(edit.type==='update') {
    editableRow(next,edit.name);
    requireValue(object(edit.patch)&&Object.keys(edit.patch).every(key=>fields.has(key)),'Unsupported property field; identifier and type are immutable');
    const declaration=next.general.properties[edit.name];
    for(const [key,value]of Object.entries(edit.patch)) {
      if(value===undefined)delete declaration[key];else declaration[key]=structuredClone(value);
    }
    validate(next,edit.name);
  } else if(edit.type==='delete') {
    editableRow(next,edit.name);delete next.general.properties[edit.name];
  } else throw new Error('Unsupported property definition edit');
  return next;
}
