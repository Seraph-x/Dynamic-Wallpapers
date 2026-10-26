import { test } from 'node:test';
import assert from 'node:assert/strict';

const moduleURL = new URL('../Sources/WallpaperApp/Resources/SceneRuntime/scene-properties.mjs', import.meta.url);
const api = () => import(moduleURL);
const definitions = () => ({
  enabled: { type: 'bool', value: true, text: 'Enabled', order: 1 },
  amount: { type: 'slider', value: .4, min: 0, max: 1, step: .1 },
  unbounded: { type: 'slider', value: -2 },
  tint: { type: 'color', value: '0.2 0.4 0.6' },
  title: { type: 'textinput', value: '' },
  choice: { type: 'combo', value: 'a', options: [{ label: 'A', value: 'a' }, { label: 'Empty', value: '' }] },
});
const project = properties => ({ general: { properties }, preset: { legacy: 4, enabled: false } });

test('catalog preserves declarations and preset-only rows with exact general precedence', async () => {
  const { createPropertyCatalog } = await api();
  const metadata = project(definitions()), original = structuredClone(metadata);
  const catalog = createPropertyCatalog(metadata);
  assert.deepEqual(metadata, original);
  assert(Object.isFrozen(catalog));
  const enabled = catalog.find(row => row.name === 'enabled');
  assert.equal(enabled.value, true); assert.equal(enabled.readOnlyReason, undefined);
  assert(Object.isFrozen(enabled));
  assert.equal(catalog.find(row => row.name === 'legacy').readOnlyReason, 'preset-only');
  assert.equal(catalog.find(row => row.name === 'unbounded').min, undefined);
  assert.equal(catalog.find(row => row.name === 'unbounded').max, undefined);
  metadata.general.properties.choice.options[0].value = 'mutated';
  assert.equal(catalog.find(row => row.name === 'choice').options[0].value, 'a');
});

test('unrecognized metadata cannot replace catalog identity or validation policy', async () => {
  const { createPropertyCatalog, validatePropertyPatch } = await api();
  const catalog = createPropertyCatalog({ general: { properties: { actual: { type: 'bool', value: true, name: 'spoofed', raw: 'spoofed', readOnlyReason: 'spoofed' } } } });
  assert.equal(catalog[0].name, 'actual');
  assert.equal(catalog[0].raw.name, 'spoofed');
  assert.equal(validatePropertyPatch({ actual: false }, catalog).actual, false);
});

test('catalog keeps unsupported and malformed rows visible without changing defaults', async () => {
  const { createPropertyCatalog } = await api();
  const rows = {
    unknown: { type: 'future', value: { untouched: true } },
    file: { type: 'file', value: 'image.png' },
    directory: { type: 'directory', value: 'assets' },
    conditional: { type: 'bool', value: true, condition: 'other == 1' },
    emptyCondition: { type: 'bool', value: true, condition: '' },
    invalid: { type: 'bool', value: 1 },
    badBounds: { type: 'slider', value: 1, min: 2, max: 1 },
    badStep: { type: 'slider', value: 1, step: 0 },
    badColor: { type: 'color', value: '1 1' },
    badOptions: { type: 'combo', value: '1', options: [{ label: 'one', value: 1 }] },
    badDefault: { type: 'slider', value: 3, max: 2 },
    scalar: 7,
    ['__proto__']: { type: 'bool', value: false },
    constructor: { type: 'bool', value: false },
    prototype: { type: 'bool', value: false },
    toString: { type: 'bool', value: false },
  };
  const original = structuredClone(rows), catalog = createPropertyCatalog(project(rows));
  for (const name of Object.keys(rows)) {
    const row = catalog.find(value => value.name === name);
    assert(row, name); assert.deepEqual(row.raw, original[name]);
    assert.equal(row.readOnlyReason === undefined, ['emptyCondition', 'constructor', 'prototype', 'toString'].includes(name), name);
  }
  assert.deepEqual(rows, original);
  assert.equal(catalog.find(row => row.name === '__proto__').readOnlyReason, 'unsupported-name');
  for (const metadata of [{ general: [] }, { general: { properties: [] } }, { preset: [] }]) assert.throws(() => createPropertyCatalog(metadata), /metadata/);
});

test('patches validate all values atomically without coercion, mutation or step-grid invention', async () => {
  const { createPropertyCatalog, validatePropertyPatch } = await api();
  const catalog = createPropertyCatalog(project(definitions()));
  const patch = { enabled: false, amount: .35, tint: '0 1 .5', title: '', choice: '', unbounded: -1000000 };
  const result = validatePropertyPatch(patch, catalog);
  assert.deepEqual({ ...result }, patch); assert.notEqual(result, patch); assert.equal(Object.getPrototypeOf(result), null);
  assert.equal(catalog.find(row => row.name === 'amount').value, .4);
  for (const invalid of [
    { missing: true }, { legacy: 5 }, { enabled: 0 }, { amount: true }, { amount: '0.5' }, { amount: NaN }, { amount: Infinity }, { amount: -1 },
    { tint: '0 1' }, { tint: '0 1 2' }, { tint: '0 1 NaN' }, { tint: '0 1 0x1' }, { tint: [0, 1, 0] },
    { title: null }, { title: {} }, { choice: 'absent' }, { choice: 1 }, { enabled: false, amount: 2 },
  ]) assert.throws(() => validatePropertyPatch(invalid, catalog), /property|Property/, JSON.stringify(invalid));
  assert.equal(patch.enabled, false); assert.equal(catalog.find(row => row.name === 'enabled').value, true);
});

test('wire rejects arrays, null, nested/nonfinite values and accepts exact own prototype-like names', async () => {
  const { validatePropertyWire, createPropertyCatalog, validatePropertyPatch } = await api();
  for (const patch of [null, [], 1, 'a', { a: null }, { a: {} }, { a: [] }, { a: undefined }, { a: NaN }, { a: Infinity }]) assert.throws(() => validatePropertyWire(patch));
  const patch = JSON.parse('{"constructor":true,"prototype":false,"toString":true}');
  const catalog = createPropertyCatalog({ general: { properties: Object.fromEntries(Object.keys(patch).map(name => [name, { type: 'bool', value: false }])) } });
  assert.deepEqual({ ...validatePropertyPatch(patch, catalog) }, patch);
  assert.equal(validatePropertyWire(patch), patch);
});

test('RGB separators match the pinned ECMAScript whitespace grammar exactly', async () => {
  const { createPropertyCatalog, validatePropertyPatch } = await api();
  const catalog = createPropertyCatalog({ general: { properties: { tint: { type: 'color', value: '0 1 .5' } } } });
  const valid = '\uFEFF0\u00A01\u2028.5\uFEFF';
  assert.equal(validatePropertyPatch({ tint: valid }, catalog).tint, valid);
  assert.throws(() => validatePropertyPatch({ tint: '0\u00851 .5' }, catalog), /Invalid property/);
});

test('property names and combo string values preserve distinct Unicode scalar sequences', async () => {
  const { createPropertyCatalog, validatePropertyPatch } = await api();
  const composed = '\u00E9', decomposed = 'e\u0301';
  const catalog = createPropertyCatalog({ general: { properties: {
    [composed]: { type: 'textinput', value: 'first' },
    [decomposed]: { type: 'textinput', value: 'second' },
    choice: { type: 'combo', value: composed, options: [{ label: 'Same label', value: composed }] },
  } } });
  assert.equal(catalog.length, 3);
  const patch = validatePropertyPatch({ [composed]: 'new first', [decomposed]: 'new second' }, catalog);
  assert.equal(Object.keys(patch).length, 2);
  assert.equal(patch[composed], 'new first'); assert.equal(patch[decomposed], 'new second');
  assert.throws(() => validatePropertyPatch({ choice: decomposed }, catalog), /Invalid property/);
  assert.equal(validatePropertyPatch({ choice: composed }, catalog).choice, composed);
});

test('pinned Main setProperties cannot faithfully deliver __proto__ as an own wire entry', () => {
  const props = JSON.parse('{"__proto__":true}'), wire = {};
  // Exact wire construction in the pinned 3.0.0 public setProperties method.
  for (const [name, value] of Object.entries(props)) wire[name] = { value };
  assert.equal(Object.hasOwn(wire, '__proto__'), false);
  assert.deepEqual(Object.entries(wire), []);
});
