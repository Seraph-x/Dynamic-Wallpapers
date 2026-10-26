import { validatePropertyWire } from './scene-properties.mjs';

const fits = new Set(['cover', 'contain']);
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const finite = (value, min, max) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
const identity = value => typeof value === 'string' && value.length > 0 && value.length <= 128;
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };

export function projectPath(value) {
  requireValue(typeof value === 'string' && value.length > 0 && !/[\\:%\x00-\x1f\x7f?#]/.test(value), 'Invalid scene project path');
  requireValue(value.split('/').every(part => part !== '' && part !== '.' && part !== '..'), 'Invalid scene project path');
  return value.split('/').map(encodeURIComponent).join('/');
}

export function validateConfig(config) {
  requireValue(record(config) && config.version === 1, 'Unsupported scene configuration');
  requireValue(identity(config.sceneID) && Number.isSafeInteger(config.generation) && config.generation > 0, 'Invalid scene identity');
  requireValue(record(config.project) && ['loose', 'package'].includes(config.project.representation), 'Invalid scene representation');
  projectPath(config.project.entryPath);
  requireValue(config.project.entryPath.toLowerCase().endsWith(config.project.representation === 'loose' ? '.json' : '.pkg'), 'Scene entry does not match representation');
  requireValue(record(config.viewport) && finite(config.viewport.width, 1, 2147483647) && finite(config.viewport.height, 1, 2147483647), 'Invalid scene viewport');
  requireValue(finite(config.fps, 1, 2147483647) && fits.has(config.fit), 'Invalid scene rendering controls');
  requireValue(finite(config.volume, 0, 1) && typeof config.muted === 'boolean', 'Invalid scene audio controls');
  return config;
}

const fields = {
  play: [], pause: [], destroy: [], volume: ['volume', 'muted'], fit: ['fit'], fps: ['fps'],
  pointer: ['kind', 'x', 'y'],
  properties: ['properties'],
};
export function validateCommand(command, config) {
  requireValue(record(command) && identity(command.id) && Object.hasOwn(fields, command.type), 'Invalid scene command');
  const allowed = new Set(['id', 'type', 'sceneID', 'generation', ...fields[command.type]]);
  requireValue(Object.keys(command).every(key => allowed.has(key)), 'Unexpected scene command field');
  requireValue(command.sceneID === undefined || command.sceneID === config.sceneID, 'Stale scene identity');
  requireValue(command.generation === undefined || command.generation === config.generation, 'Stale scene generation');
  switch (command.type) {
    case 'volume': requireValue(finite(command.volume, 0, 1) && typeof command.muted === 'boolean', 'Invalid volume'); break;
    case 'fit': requireValue(fits.has(command.fit), 'Invalid fit'); break;
    case 'fps': requireValue(finite(command.fps, 1, 2147483647), 'Invalid FPS'); break;
    case 'properties': validatePropertyWire(command.properties); break;
    case 'pointer':
      requireValue(['move', 'leave', 'click'].includes(command.kind), 'Invalid pointer kind');
      requireValue(command.kind === 'leave' && command.x === undefined && command.y === undefined || finite(command.x, 0, 1) && finite(command.y, 0, 1), 'Invalid pointer coordinates');
      break;

  }
  return command;
}
