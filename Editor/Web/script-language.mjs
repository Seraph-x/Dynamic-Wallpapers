const vectors = new Set(['origin','scale','angles','color']);
const scalars = new Set(['alpha','brightness','maxwidth','pointsize','volume','intensity','exponent']);
const missingInitialScalars = new Set(['maxwidth','pointsize','volume']);
const unsafeAnimationScalars = new Set(['maxwidth','pointsize','volume','intensity','exponent']);
const effectTarget = target => typeof target === 'string' && /^effects\[(0|[1-9]\d*)\]\.visible$/.test(target) && Number.isSafeInteger(Number(target.slice(8,-9)));

export function scriptValueKind(target) {
  if (vectors.has(target)) return 'vector';
  if (scalars.has(target)) return 'scalar';
  if (target === 'visible' || effectTarget(target)) return 'boolean';
  return target === 'text' ? 'text' : 'unknown';
}

const field = (label, detail, info) => ({label,type:'property',detail,...(info ? {info} : {})});
const method = (label, detail, info) => ({label,type:'function',detail,...(info ? {info} : {})});
const fields = (names, detail) => names.split(' ').map(label => field(label,detail));
const methods = (names, detail) => names.split(' ').map(label => method(label,detail));
const vectorMethods = 'copy add subtract multiply divide mix length lengthSqr distance distanceSqr normalize equals isFinite negate dot reflect project min max clamp abs sign round floor ceil fract mod step smoothStep toString toConfigString';
const vectorMembers = [...fields('x y z','number'),...methods(vectorMethods + ' cross refract angleBetween toSpherical','Vec3 operation; arithmetic returns a new vector')];
const proxyVectorMembers = [...fields('x y z','number; vector snapshot'),
  ...methods('add multiply','Mutates this vector snapshot in place; returns the same vector'),
  ...methods('subtract divide','Returns a new vector snapshot'),method('copy','Returns a new Vec3'),
  ...methods('length lengthSqr','() => number'),method('toArray','() => number[]')];
const angleMembers = [...fields('x y z','number; degrees; writes through to layer angles'),
  ...methods('add subtract multiply','Mutates layer angles in place; returns the same live proxy'),method('toArray','() => number[]; degrees')];
const stringMembers = [field('length','number'),...methods('includes startsWith endsWith slice substring replace replaceAll trim toLowerCase toUpperCase split','String operation')];
const arrayMembers = [field('length','number'),...methods('slice map forEach includes join','Array operation')];
const engine = [
  ...fields('runtime frametime timeOfDay','number'),field('canvasSize','Vec3 with width/height; scene design size'),
  field('screenResolution','{x:number,y:number}; screen pixels'),field('userProperties','Initial user-property values','The current app does not dispatch live property changes.'),
  method('registerAudioBuffers','(resolution:number) => {left,right,average:Float32Array}','Main supplies real spectrum or silence; native snapshot preview supplies zero spectrum.'),
  ...['16','32','64'].map(n => ({label:'AUDIO_RESOLUTION_'+n,type:'constant',detail:n})),
  method('setTimeout','(callback, milliseconds) => cancel function'),method('setInterval','(callback, milliseconds) => cancel function'),
  ...methods('clearTimeout clearInterval','(cancelHandle) => void'),method('registerAsset','(path:string) => string; returns the same asset path'),
  ...methods('isRunningInEditor isScreensaver isWallpaper isDesktopDevice isMobileDevice isPortrait isLandscape','() => boolean'),
];
const scopes = {
  engine,
  'engine.screenResolution': fields('x y','number; screen pixels'),
  'engine.canvasSize': [...vectorMembers,...fields('width height','number; scene design size')],
  input: [...fields('cursorWorldPosition cursorScreenPosition cursorPosition cursorPositionLast','Vec3; world, screen or normalized coordinates'),field('cursorLeftDown','boolean')],
  WEMath: [...['deg2rad','rad2deg'].map(label => ({label,type:'constant',detail:'number; angle conversion factor'})),...methods('mix lerp clamp saturate smoothstep smoothStep random randomInt degrees radians','Numeric helper')],
  WEColor: methods('hsv2rgb rgb2hsv normalizeColor expandColor','(color:Vec3) => Vec3'),
  WEVector: methods('add subtract scale length dot normalize vectorAngle2 angleVector2','Vector helper; angles in degrees'),
  Vec3: [method('fromSpherical','(radius, thetaDegrees, phiDegrees) => Vec3')],
  Vec2: [], Vec4: [],
  localStorage: [...methods('getItem setItem delete removeItem clear key','Scene storage operation; persistence depends on the host'),field('length','number'),...['SCREEN','GLOBAL'].map(name => ({label:'LOCATION_'+name,type:'constant',detail:'Storage location; host-provider dependent'}))],
  MediaPlaybackEvent: ['STOPPED','PLAYING','PAUSED'].map((name,index) => ({label:'PLAYBACK_'+name,type:'constant',detail:String(index)})),
  Math: [...methods('abs min max floor ceil round trunc sin cos tan asin acos atan atan2 sqrt pow exp log random hypot sign','JavaScript Math function'),{label:'PI',type:'constant',detail:'number'}],
  Date: methods('now parse UTC','JavaScript Date static function'),
};
const objectLayer = [
  ...fields('name text font alignment','string'),field('id','number | string'),
  ...fields('alpha brightness pointsize','number'),...fields('visible perspective','boolean'),
  ...fields('origin originalOrigin scale color size','Vector snapshot; limited methods'),field('angles','Live angle proxy; arithmetic writes through; degrees'),
  ...methods('getParent getChildren','Layer relationship; may be absent or empty'),
];
const textLayer = [...fields('text font','string'),field('pointsize','number'),field('visible','boolean'),field('origin','Vector snapshot; limited methods'),...fields('color angles scale','number[]; text sandbox snapshots')];
const objectScene = [method('getLayer','(name:string) => layer proxy','A missing name returns a neutral proxy; choose an existing layer.'),method('enumerateLayers','() => layer proxies'),method('getLayerIndex','(layerOrName) => number')];
const textScene = [method('getLayer','(name:string) => {text:string}','The text sandbox provides a text snapshot, not a writable layer proxy.')];
const globals = [
  ...['engine','input','thisLayer','thisScene','scriptProperties','shared','WEMath','WEColor','WEVector','localStorage','MediaPlaybackEvent','Math','Date'].map(label => ({label,type:'variable',detail:'SceneScript or JavaScript object'})),
  ...methods('createScriptProperties','() => property builder'),...['Vec2','Vec3','Vec4','String','Number','Boolean','Array','Object'].map(label => ({label,type:'class',detail:'Constructor'})),
  ...'export function return const let if else for while switch case break continue new throw try catch true false null undefined'.split(' ').map(label => ({label,type:'keyword',detail:'JavaScript syntax'})),
];

/** Positive static hints only; never inspect or evaluate the author's source. */
export function completionOptions(target, scope = '') {
  if (typeof scope !== 'string') throw new TypeError('Completion scope must be a string');
  const kind = scriptValueKind(target);
  if (kind === 'unknown') return [];
  const text = target === 'text';
  let options = [];
  if (!scope) options = [...globals,...(!text ? [{label:'thisObject',type:'variable',detail:'Alias of thisLayer in the object/effect sandbox'}] : [])];
  else if (scope === 'value') options = kind === 'vector' ? vectorMembers : kind === 'text' ? stringMembers : [];
  else if (scope === 'thisLayer' || scope === 'thisObject' && !text) options = text ? textLayer : objectLayer;
  else if (scope === 'thisScene') options = text ? textScene : objectScene;
  else if (/^input\.cursor(?:WorldPosition|ScreenPosition|Position|PositionLast)$/.test(scope)) options = vectorMembers;
  else if (/^this(?:Layer|Object)\.(origin|originalOrigin|scale|color|angles|size)$/.test(scope) && !(text && scope.startsWith('thisObject.'))) {
    const property = scope.split('.')[1];
    options = text ? property === 'origin' ? proxyVectorMembers : ['color','angles','scale'].includes(property) ? arrayMembers : [] : property === 'angles' ? angleMembers : proxyVectorMembers;
  } else options = Object.hasOwn(scopes,scope) ? scopes[scope] : [];
  return options.map(option => ({...option}));
}

const capture = kind => kind === 'vector' ? 'new Vec3(value)' : 'value';
function changedValue(target, baseline = 'initial') {
  if (target === 'origin') return `${baseline}.add(new Vec3(10, 0, 0))`;
  if (target === 'angles') return `${baseline}.add(new Vec3(0, 0, 10))`;
  if (target === 'scale') return `${baseline}.multiply(1.1)`;
  if (target === 'color') return `${baseline}.multiply(0.5)`;
  if (target === 'alpha' || target === 'volume') return `WEMath.clamp(${baseline} * 0.5, 0, 1)`;
  if (scriptValueKind(target) === 'scalar') return `${baseline} * 0.5`;
  if (scriptValueKind(target) === 'boolean') return `!${baseline}`;
  if (target === 'text') return `${baseline} + ' ✓'`;
  return baseline;
}
function stateStarter(kind, callback) {
  return `let initial;\nlet current;\n\nexport function init(value) {\n  initial = ${capture(kind)};\n  current = initial;\n  return current;\n}\n\n${callback}\n\nexport function update(value) {\n  return current;\n}\n`;
}
function passthrough(callback = '', initBody = '') {
  return `export function init(value) {\n${initBody}  return value;\n}\n${callback ? '\n' + callback + '\n' : ''}\nexport function update(value) {\n  return value;\n}\n`;
}
function updateExpression(target) {
  if (target === 'origin') return 'initial.add(new Vec3(Math.sin(engine.runtime) * 10, 0, 0))';
  if (target === 'angles') return 'initial.add(new Vec3(0, 0, Math.sin(engine.runtime) * 10))';
  if (target === 'scale') return 'initial.multiply(1 + 0.1 * Math.sin(engine.runtime))';
  if (target === 'color') return 'initial.multiply(0.75 + 0.25 * Math.sin(engine.runtime))';
  if (target === 'alpha' || target === 'volume') return 'WEMath.clamp(initial * (0.75 + 0.25 * Math.sin(engine.runtime)), 0, 1)';
  if (scriptValueKind(target) === 'scalar') return 'initial * (1 + 0.1 * Math.sin(engine.runtime))';
  if (scriptValueKind(target) === 'boolean') return 'Math.sin(engine.runtime) >= 0';
  return target === 'text' ? "initial + ' ' + Math.floor(engine.runtime)" : 'initial';
}
function audioExpression(target) {
  if (target === 'color') return 'initial.multiply(0.5 + level * 0.5)';
  if (scriptValueKind(target) === 'vector') return 'initial.multiply(1 + level * 0.1)';
  if (target === 'alpha' || target === 'volume') return 'WEMath.clamp(initial * level, 0, 1)';
  if (scriptValueKind(target) === 'scalar') return 'initial * (1 + level * 0.1)';
  if (scriptValueKind(target) === 'boolean') return 'level > 0.05';
  return target === 'text' ? "initial + ' ' + Math.round(level * 100) + '%'" : 'initial';
}

/** Complete modules replace drafts explicitly; these never append to source. */
export function lifecycleTemplates(target) {
  const kind = scriptValueKind(target), changed = changedValue(target);
  const initial = `let initial;\n\nexport function init(value) {\n  initial = ${capture(kind)};\n  return initial;\n}\n`;
  const sources = {
    init: missingInitialScalars.has(target) ? passthrough() : initial + '\nexport function update(value) {\n  return initial;\n}\n',
    update: missingInitialScalars.has(target) ? passthrough() : initial + `\nexport function update(value) {\n  return ${updateExpression(target)};\n}\n`,
    properties: passthrough('export function applyUserProperties(properties) {\n  // The host delivers initial values; live changes are not wired in this app.\n  shared.userPropertyKeys = Object.keys(properties);\n}'),
    cursor: passthrough('export function cursorClick(event) {\n  // The selected layer must be rendered and hit-testable.\n  shared.cursorWorldPosition = {x: event.worldPosition.x, y: event.worldPosition.y, z: event.worldPosition.z};\n}'),
    media: stateStarter(kind, 'export function mediaPropertiesChanged(event) {\n  shared.mediaTitle = event.title;\n}'),
    animation: stateStarter(kind, `export function animationEvent(event, value) {\n  // Requires an authored event on this layer.\n  current = ${changed};\n  return current;\n}`),
    resize: passthrough('export function resizeScreen(size) {\n  shared.screenSize = {x: size.x, y: size.y};\n}'),
    timer: passthrough('', '  engine.setTimeout(() => { shared.timerElapsed = true; }, 1000);\n'),
    audio: `const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);\n${initial}\nexport function update(value) {\n  const level = WEMath.clamp(audio.average[0], 0, 1);\n  return ${audioExpression(target)};\n}\n`,
  };
  return Object.entries(sources).map(([id,source]) => {
    const reason = kind === 'unknown' ? 'UNSUPPORTED_TARGET' : id === 'media' ? 'MEDIA_HOST_DISABLED' : id === 'cursor' && effectTarget(target) ? 'EFFECT_CURSOR_UNSUPPORTED' : id === 'animation' && unsafeAnimationScalars.has(target) ? 'ANIMATION_SCALAR_UNSUPPORTED' : id === 'audio' && missingInitialScalars.has(target) ? 'INITIAL_VALUE_UNAVAILABLE' : null;
    return {id,source,available:reason === null,reason};
  });
}
