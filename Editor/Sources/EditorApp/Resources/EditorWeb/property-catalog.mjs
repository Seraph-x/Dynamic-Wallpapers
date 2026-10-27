const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const finite = value => typeof value === 'number' && Number.isFinite(value);
const scalar = value => typeof value === 'boolean' || typeof value === 'string' || finite(value);
const supported = new Set(['bool', 'slider', 'color', 'textinput', 'combo']);
const decimal = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i;
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };

function freezeCopy(value) {
  const copy = structuredClone(value);
  function freeze(item) {
    if (item !== null && typeof item === 'object') {
      Object.values(item).forEach(freeze);
      Object.freeze(item);
    }
    return item;
  }
  return freeze(copy);
}

function validColor(value) {
  if (typeof value !== 'string') return false;
  const components = value.trim().split(/\s+/);
  return components.length === 3 && components.every(part => decimal.test(part) && finite(Number(part)) && Number(part) >= 0 && Number(part) <= 1);
}

function validOptions(options) {
  return Array.isArray(options) && options.length > 0 && options.every(option => record(option) && typeof option.label === 'string' && typeof option.value === 'string');
}

function validValue(value, declaration) {
  switch (declaration.type) {
    case 'bool': return typeof value === 'boolean';
    case 'slider': return finite(value) && (declaration.min === undefined || value >= declaration.min) && (declaration.max === undefined || value <= declaration.max);
    case 'color': return validColor(value);
    case 'textinput': return typeof value === 'string';
    case 'combo': return typeof value === 'string' && declaration.options.some(option => option.value === value);
    default: return false;
  }
}

function readOnlyReason(name, declaration, presetOnly) {
  if (presetOnly) return 'preset-only';
  // The pin constructs ordinary wire/live objects: this key changes their
  // prototype instead of delivering an own property. Other names are legal.
  if (name === '__proto__') return 'unsupported-name';
  if (!record(declaration)) return 'invalid-declaration';
  if (!supported.has(declaration.type)) return 'unsupported-type';
  if (Object.hasOwn(declaration, 'condition') && declaration.condition !== '') return 'unsupported-condition';
  if (declaration.text !== undefined && typeof declaration.text !== 'string' || declaration.order !== undefined && !finite(declaration.order)) return 'invalid-declaration';
  if (declaration.type === 'slider') {
    if (declaration.min !== undefined && !finite(declaration.min) || declaration.max !== undefined && !finite(declaration.max)) return 'invalid-declaration';
    if (declaration.min !== undefined && declaration.max !== undefined && declaration.min > declaration.max) return 'invalid-declaration';
    if (declaration.step !== undefined && (!finite(declaration.step) || declaration.step <= 0)) return 'invalid-declaration';
  }
  if (declaration.type === 'combo' && !validOptions(declaration.options)) return 'invalid-declaration';
  return validValue(declaration.value, declaration) ? undefined : 'invalid-declaration';
}

export function createPropertyCatalog(project) {
  requireValue(record(project), 'Invalid property metadata');
  requireValue(project.general === undefined || record(project.general), 'Invalid general property metadata');
  const general = project.general?.properties;
  requireValue(general === undefined || record(general), 'Invalid general property metadata');
  requireValue(project.preset === undefined || record(project.preset), 'Invalid preset property metadata');
  const names = new Set([...Object.keys(project.preset ?? {}), ...Object.keys(general ?? {})]);
  const rows = [...names].map(name => {
    const presetOnly = !Object.hasOwn(general ?? {}, name);
    const raw = freezeCopy(presetOnly ? project.preset[name] : general[name]);
    const declaration = !presetOnly && record(raw) ? raw : {};
    return Object.freeze({ ...declaration, name, raw, readOnlyReason: readOnlyReason(name, raw, presetOnly) });
  });
  // Invalid order values remain visible, ordered by stable property identity.
  rows.sort((a, b) => (finite(a.order) ? a.order : Infinity) - (finite(b.order) ? b.order : Infinity) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return Object.freeze(rows);
}

export function validatePropertyWire(patch) {
  requireValue(record(patch), 'Invalid property patch');
  requireValue(Object.values(patch).every(scalar), 'Property values must be finite JSON scalars');
  return patch;
}

export function validatePropertyPatch(patch, catalog) {
  validatePropertyWire(patch);
  const declarations = new Map(catalog.map(row => [row.name, row]));
  const result = Object.create(null);
  for (const [name, value] of Object.entries(patch)) {
    const declaration = declarations.get(name);
    requireValue(declaration !== undefined, `Unknown property: ${name}`);
    requireValue(declaration.readOnlyReason === undefined, `Read-only property ${name}: ${declaration.readOnlyReason}`);
    requireValue(validValue(value, declaration), `Invalid property value: ${name}`);
    result[name] = value;
  }
  return result;
}
