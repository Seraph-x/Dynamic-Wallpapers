import {patchSceneResourceScripts} from './scene-resource-script-patches.mjs';

// Build-only transforms of the hash-verified, untouched WebWallGL 3.0.0 entry.
// Every anchor count is part of the pin: unknown upstream source is rejected.
const edits=[
 {
  id:'explicit-external-media-precedence',reason:'A selected native provider remains authoritative when empty; never substitute another live player, wallpaper audio or simulated media.',
  before:'      const currentMediaDriver = () => hasLiveMedia(liveMediaOverride) ? liveMediaOverride : hasLiveMedia(rt.mediaSource) ? rt.mediaSource : (wallpaperAudio.hasCurrent() ? wallpaperAudio : null) ?? simMedia;',
  after:'      const currentMediaDriver = () => rt.mediaSource ?? (hasLiveMedia(liveMediaOverride) ? liveMediaOverride : (wallpaperAudio.hasCurrent() ? wallpaperAudio : null) ?? simMedia);',
 },
 {
  id:'explicit-external-media-control-precedence',reason:'Transport actions target the same explicitly selected provider as metadata, including an empty external source.',
  before:'      const controlMediaDriver = () => mediaButtons.pickControlDriver(liveMediaOverride, injectedControlSource(), currentMediaDriver());',
  after:'      const controlMediaDriver = () => mediaButtons.hasMediaControl(rt.mediaSource) ? rt.mediaSource : mediaButtons.pickControlDriver(liveMediaOverride, injectedControlSource(), currentMediaDriver());',
 },
 {
  id:'media-artwork-task-ownership',reason:'Track real asynchronous PNG decoding/upload so a paused media acknowledgement can wait for its pixels.',
  before:'      let mediaThumbnailLastSrc;',
  after:'      let mediaThumbnailLastSrc;\n      let mediaArtworkTask;',
 },
 {
  id:'media-empty-artwork-invalidation',reason:'Clearing an item invalidates its pending upload before it can attach artwork or colors to a later empty snapshot.',
  before:'            if (mediaThumbnailLastSrc !== snap.thumbnail && typeof snap.thumbnail === "string" && snap.thumbnail) {',
  after:'            if (!snap.hasThumbnail || !snap.thumbnail) mediaThumbnailLastSrc = void 0;\n            if (mediaThumbnailLastSrc !== snap.thumbnail && typeof snap.thumbnail === "string" && snap.thumbnail) {',
 },
 {
  id:'media-artwork-awaitable-upload',reason:'Retain the actual source decode/upload promise without introducing a new polling or simulated path.',
  before:'              void (async () => {\n                try {\n                  const blob = await fetch(nextSrc, { cache: "no-store" }).then(',
  after:'              mediaArtworkTask = (async () => {\n                try {\n                  const blob = await fetch(nextSrc, { cache: "no-store" }).then(',
 },
 {
  id:'media-artwork-retired-upload-rejection',reason:'Late artwork decode cannot touch retired GPU resources or a newer/empty snapshot.',
  before:'                  if (mediaThumbnailLastSrc !== nextSrc) {',
  after:'                  if (disposed || mediaThumbnailLastSrc !== nextSrc || mediaSnapshot().thumbnail !== nextSrc) {',
 },
 {
  id:'media-native-png-without-fetch',reason:'Decode validated native PNG data directly into a Blob; the trusted shell keeps connect-src self and never needs data-URL network access.',
  before:`                  const blob = await fetch(nextSrc, { cache: "no-store" }).then(
                    (r) => r.ok ? r.blob() : null
                  );`,
  after:`                  const nativePNGPrefix = "data:image/png;base64,";
                  const blob = nextSrc.startsWith(nativePNGPrefix)
                    ? new Blob([Uint8Array.from(atob(nextSrc.slice(nativePNGPrefix.length)), c => c.charCodeAt(0))], { type: "image/png" })
                    : await fetch(nextSrc, { cache: "no-store" }).then(r => r.ok ? r.blob() : null);`,
 },
 {
  id:'media-refresh-frame-ownership',reason:'Expose the existing real paused/playing frame promise through a fixed data-only media refresh method.',
  before:'  let applyLiveImpl;\n  let pauseImpl;',
  after:'  let applyLiveImpl;\n  let refreshMediaImpl;\n  let pauseImpl;',
 },
 {
  id:'media-refresh-controller',reason:'Media updates await an actual frame without writing unrelated user properties or granting Editor controls.',
  before:'    applyUserProperties(props) {\n      if (applyLiveImpl) applyLiveImpl(props);',
  after:'    refreshMedia() {\n      if (!refreshMediaImpl) return Promise.reject(new Error("Scene media is not ready"));\n      return refreshMediaImpl();\n    },\n    applyUserProperties(props) {\n      if (applyLiveImpl) applyLiveImpl(props);',
 },
 {
  id:'public-media-frame-result',reason:'Native command acknowledgements wait for the frame that consumes the newly selected external snapshot.',
  before:'      rt.mediaSource = src ?? null;\n      rt.mediaDisabled = false;\n    },',
  after:'      rt.mediaSource = src ?? null;\n      rt.mediaDisabled = false;\n      return rt.sceneCtl?.refreshMedia?.();\n    },',
 },
 {
  id:'text-binding-preflight',reason:'Reject invalid directly bound text/font values before a live patch changes any properties.',
  before:'      const applyLiveProps = (wire) => {\n        if (disposed) return;\n        const properties = scene.properties ||= {};',
  after:`      const applyLiveProps = (wire) => {
        if (disposed) return;
        for (const layer of scene.layers) {
          if (!layer.isText) continue;
          const src = layer.srcObject;
          for (const field of ["text", "pointsize"]) {
            const name = typeof src?.[field]?.user === "string" ? src[field].user : null;
            if (!name || !Object.hasOwn(wire || {}, name)) continue;
            const entry = wire[name];
            const value = entry && typeof entry === "object" && Object.hasOwn(entry, "value") ? entry.value : entry;
            if (field === "text" && typeof value !== "string") throw new TypeError("Bound text must be a string");
            if (field === "pointsize" && (typeof value !== "number" || !Number.isFinite(value) || value <= 0)) throw new TypeError("Bound font size must be a finite positive number");
          }
        }
        const properties = scene.properties ||= {};`,
 },
 {
  id:'text-binding-live-state',reason:'Update actual text layer state and original-box layout when direct text/font bindings change.',
  before:'          const uA = boundUserName(src.alpha);\n          if (uA && uA in changed) layer.alpha = scn.parseNum(src.alpha, 1);',
  after:`          if (layer.isText) {
            const textName = typeof src.text?.user === "string" ? src.text.user : null;
            const sizeName = typeof src.pointsize?.user === "string" ? src.pointsize.user : null;
            const textChanged = textName && Object.hasOwn(changed, textName);
            const sizeChanged = sizeName && Object.hasOwn(changed, sizeName);
            if (textChanged) layer.text = src.text.value;
            if (sizeChanged) layer.textPointsize = src.pointsize.value;
            if (textChanged || sizeChanged) {
              const item = textWidgets.find(item => item.layer === layer);
              if (item) {
                const box = scn.parseVec2(src.size || "0 0");
                const em = TEXT_EM_SCALE * Math.max(1, layer.textPointsize);
                const tintMask = wtext.textLayerHasTintMask(layer);
                const effects = (layer.effects || []).some(effect => effect && effect.visible !== false);
                item.boxW = box[0] > 0 ? box[0] : em * 4;
                item.boxH = box[1] > 0 ? box[1] : em * 1.6;
                item.margin = effects && !tintMask ? 0 : Math.min(tintMask ? 8 : 256, wtext.textCanvasMargin(em, 0));
                layer.size = [item.boxW + item.margin * 2, item.boxH + item.margin * 2];
                item.bindingReflow = true;
                item.lastKey = null;
              }
            }
          }
          const uA = boundUserName(src.alpha);
          if (uA && uA in changed) layer.alpha = scn.parseNum(src.alpha, 1);`,
 },
 {
  id:'text-binding-reflow-shrink',reason:'Recompute both grown and shrunken bound text quads instead of retaining a previous larger canvas.',
  before:'                const grow = wtext.textCanvasMarginGrow(layout, bw, bh, M);\n                if (!!it.sandbox?.hasMediaHook',
  after:`                const grow = wtext.textCanvasMarginGrow(layout, bw, bh, M);
                if (it.bindingReflow) {
                  layer.size[0] = bw + grow * 2;
                  layer.size[1] = bh + grow * 2;
                  it.bindingReflow = false;
                }
                if (!!it.sandbox?.hasMediaHook`,
 },
 {
  id:'text-textures-before-draw',reason:'Draw the updated text texture in the acknowledged frame, including a single paused forced frame.',
  before:'          renderInFlight = renderer.render(scene, textures2, c.width, c.height, t, normalizeFit(rt.cfg.fit), peek.x, peek.y, roiWorld).then(() => {',
  after:`          rt.sceneTextUpdate?.(t);
          const drawingBatch = frameWaiters.splice(0);
          activeFrameWaiters.add(drawingBatch);
          renderInFlight = renderer.render(scene, textures2, c.width, c.height, t, normalizeFit(rt.cfg.fit), peek.x, peek.y, roiWorld).then(() => {`,
 },
 {
  id:'remove-post-draw-text-update',reason:'Text scripts and texture updates run once before drawing rather than after the frame is already visible.',
  before:'            try {\n              if (rt.sceneTextUpdate) rt.sceneTextUpdate(t);\n            } catch (e) {\n            }\n            flushEditorWaiters();',
  after:'            flushEditorWaiters();',
 },
 {
  id:'frame-owned-acknowledgements',reason:'An older asynchronous frame can resolve only the waiters captured before that draw.',
  before:'flushEditorWaiters();',after:'flushEditorWaiters(drawingBatch);',matches:2,
 },
 {
  id:'frame-batch-lifetime',reason:'Track pending and active frame batches so errors and disposal reject every affected promise.',
  before:'      const frameWaiters = [];\n      const flushEditorWaiters = () => {\n        for (const w of frameWaiters.splice(0)) w.resolve();\n      };\n      const failEditorWaiters = (err) => {\n        for (const w of frameWaiters.splice(0)) w.reject(err);',
  after:`      const frameWaiters = [];
      const activeFrameWaiters = new Set();
      const flushEditorWaiters = (batch) => {
        activeFrameWaiters.delete(batch);
        for (const w of batch) w.resolve();
      };
      const failEditorWaiters = (err) => {
        for (const w of frameWaiters.splice(0)) w.reject(err);
        for (const batch of activeFrameWaiters) for (const w of batch) w.reject(err);
        activeFrameWaiters.clear();`,
 },
 {
  id:'frame-cleanup-rejection',reason:'Destroy rejects a queued paused frame even when no renderer completion will run afterward.',
  before:'      const renderLoop = (now, forced = false) => {\n        try {',
  after:`      const previousFrameCleanup = rt.sceneCleanup;
      rt.sceneCleanup = () => {
        failEditorWaiters(new Error("scene disposed"));
        previousFrameCleanup?.();
      };
      const renderLoop = (now, forced = false) => {
        try {`,
 },
 {
  id:'scene-property-frame-result',reason:'Propagate the actual rendering promise through the existing scene property transport.',
  before:'      if (applyLiveImpl) applyLiveImpl(props);\n      else pendingWire',
  after:'      if (applyLiveImpl) return applyLiveImpl(props);\n      else pendingWire',
 },
 {
  id:'scene-property-render-frame',reason:'Public data-only updates use the same real playing/paused frame mechanism as Editor updates.',
  before:'      applyLiveImpl = applyLiveProps;',
  after:'      applyLiveImpl = props => { applyLiveProps(props); return renderOnce(); };',
 },
 {
  id:'public-property-frame-result',reason:'Callers may await data acceptance and actual drawing without receiving Editor controls.',
  before:'      rt.sceneCtl?.applyUserProperties(wire);',after:'      return rt.sceneCtl?.applyUserProperties(wire);',
 },
 {
  id:'media-refresh-render-frame',reason:'Bind media refresh to the same frame-owned renderer promise after scene preparation.',
  before:'      applyLiveImpl = props => { applyLiveProps(props); return renderOnce(); };',
  after:`      applyLiveImpl = props => { applyLiveProps(props); return renderOnce(); };
      refreshMediaImpl = async () => {
        await renderOnce();
        await mediaArtworkTask;
        if (disposed) throw new Error("scene disposed");
        return renderOnce();
      };`,
 },
];

export function patchSceneEngine(original){
  if(typeof original!=='string')throw new TypeError('Pinned renderer source must be text');
  let source=original;
  for(const edit of edits){
    const expected=edit.matches??1,parts=source.split(edit.before),actual=parts.length-1;
    if(actual!==expected)throw new Error(`Pinned renderer patch ${edit.id}: expected ${expected} anchor matches, found ${actual}`);
    source=parts.join(edit.after);
  }
  const resource=patchSceneResourceScripts(source);
  return {source:resource.source,patches:[...edits.map(({id,reason,matches=1})=>({id,reason,matches})),...resource.patches]};
}
