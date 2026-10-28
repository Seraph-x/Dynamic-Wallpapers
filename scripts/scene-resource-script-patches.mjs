const edits = [
  {
    id: 'resource-script-shared-imports',
    reason: 'Bundle the same lossless source-origin and typed runtime modules into every pinned renderer copy.',
    before: 'import { Input, ALL_FORMATS, UrlSource, VideoSampleSink } from "mediabunny";',
    after: `import { Input, ALL_FORMATS, UrlSource, VideoSampleSink } from "mediabunny";
import { createResourceOrigins } from "@dynamic-wallpapers/scene-resource-source";
import { createResourceScriptRuntime, RESOURCE_SCRIPT_UNAVAILABLE, resourceParticleConstants, setResourceParticleConstants } from "@dynamic-wallpapers/scene-resource-runtime";`,
  },
  {
    id: 'resource-script-effect-material-origin',
    reason: 'Carry the exact effect material bytes into the engine-owned source registry.',
    before: '    if (typeof onMaterialDoc === "function") onMaterialDoc(mj);',
    after: '    if (typeof onMaterialDoc === "function") onMaterialDoc(mj, me);',
  },
  {
    id: 'resource-script-renderer-state',
    reason: 'Keep one source-aware runtime beside the existing inline constant evaluator.',
    before: '  let constScriptSink = null;\n  const constScriptCache = /* @__PURE__ */ new Map();',
    after: `  let constScriptSink = null;
  let resourceScriptRuntime = null;
  const constScriptCache = /* @__PURE__ */ new Map();`,
  },
  {
    id: 'resource-script-no-failed-uniform-write',
    reason: 'A failed external evaluation must not write its authored static value or a shader default.',
    before: '    for (const [matKey, value] of Object.entries(constants || {})) {\n      const entry = lookupMatMeta(matMeta, lowerIndex, matKey);',
    after: `    for (const [matKey, value] of Object.entries(constants || {})) {
      if (value === RESOURCE_SCRIPT_UNAVAILABLE) continue;
      const entry = lookupMatMeta(matMeta, lowerIndex, matKey);`,
  },
  {
    id: 'resource-script-typed-constant-evaluation',
    reason: 'Evaluate authenticated external wrappers before the legacy inline constant path.',
    before: '  function scriptedConstants(constants, cacheKey, time, layer) {\n    if (!constants) return constants;',
    after: `  function scriptedConstants(constants, cacheKey, time, layer, kind = "effect", consumer = layer) {
    if (!constants) return constants;
    if (resourceScriptRuntime) {
      constants = resourceScriptRuntime.constants(constants, {
        consumer: consumer || layer,
        layer,
        slot: cacheKey,
        kind,
        target: cacheKey
      }, {
        runtime: time,
        frametime: lastFrametime,
        timeOfDay: daytimeFraction(),
        screenResolution: { x: renderWidth, y: renderHeight }
      });
    }`,
  },
  {
    id: 'resource-script-mesh-constants',
    reason: 'Run owned material wrappers for the actual mesh/per-mesh consumer without rebuilding geometry.',
    before: '      bindConstants(ent.uni, spec.constants || {}, ent.matMeta);',
    after: '      bindConstants(ent.uni, scriptedConstants(spec.constants || {}, "mesh|" + keyOf(spec), time, layer, "mesh", spec), ent.matMeta);',
  },
  {
    id: 'resource-script-per-mesh-same-program',
    reason: 'Rebind constants for adjacent meshes that share a shader program but use different material resources.',
    before: '      if (curProgKey === keyOf(spec)) return;\n      curProgKey = keyOf(spec);',
    after: '      curProgKey = keyOf(spec);',
  },
  {
    id: 'resource-script-particle-material-constants',
    reason: 'Use the current typed resource values when binding a custom particle material shader.',
    before: '    bindParticleMaterialConstants(gl, entry, this.matShader && this.matShader.constants || {});',
    after: '    bindParticleMaterialConstants(gl, entry, resourceParticleConstants(this) || this.matShader && this.matShader.constants || {});',
  },
  {
    id: 'resource-script-renderer-injection',
    reason: 'Expose a focused renderer injection point while keeping the owning mount responsible for disposal.',
    before: '    setConstantScriptRuntime,\n    /** 已创建的效果常量沙箱收到 applyUserProperties',
    after: `    setConstantScriptRuntime,
    setResourceScriptRuntime(value) {
      resourceScriptRuntime = value || null;
    },
    /** 已创建的效果常量沙箱收到 applyUserProperties`,
  },
  {
    id: 'resource-script-owned-asset-paths',
    reason: 'Bind returned resource byte identities to their logical package/loose paths.',
    before: '      const readAsset = async (name) => sceneDir ? await sceneDir.read(name, pkgAbort.signal) : pkg.getEntry(parsedPkg, name);',
    after: `      const resourceAssetPaths = new WeakMap();
      const readAsset = async (name) => {
        const entry = sceneDir ? await sceneDir.read(name, pkgAbort.signal) : pkg.getEntry(parsedPkg, name);
        if (entry && typeof entry === "object") resourceAssetPaths.set(entry, name);
        return entry;
      };`,
  },
  {
    id: 'resource-script-origin-registry',
    reason: 'Capture original material bytes before user-property mutation and retain one frame context for non-renderer sinks.',
    before: '      const scene = scn.parseScene(sceneJsonRaw, project);\n      const materialDocs = [];',
    after: `      const scene = scn.parseScene(sceneJsonRaw, project);
      const resourceOrigins = createResourceOrigins();
      let resourceScriptRuntime = null;
      const resourceScriptFrame = { runtime: 0, frametime: 1 / 60, timeOfDay: 0, screenResolution: { x: c.width, y: c.height } };
      let applyResourceParticleScripts = () => {};
      const materialDocs = [];`,
  },
  {
    id: 'resource-script-material-capture',
    reason: 'Authenticate material wrappers against exact original bytes and logical paths before normal resolver mutations.',
    before: `      const registerMaterialDoc = (doc) => {
        if (noMaterialProps || !doc || typeof doc !== "object") return doc;
        materialDocs.push(doc);`,
    after: `      const registerMaterialDoc = (doc, entry) => {
        if (!doc || typeof doc !== "object") return doc;
        const path = entry && resourceAssetPaths.get(entry);
        if (path) resourceOrigins.capture(path, entry, doc, "material");
        if (noMaterialProps) return doc;
        materialDocs.push(doc);`,
  },
  {
    id: 'resource-script-direct-material-bytes',
    reason: 'Pass direct material bytes through the same source capture used by effect materials.',
    before: '      const readMaterialDoc = (entry) => registerMaterialDoc(eff.parseJsonTolerant(readText(entry)));',
    after: '      const readMaterialDoc = (entry) => registerMaterialDoc(eff.parseJsonTolerant(readText(entry)), entry);',
  },
  {
    id: 'resource-script-tint-evaluation',
    reason: 'Evaluate generic tint wrappers in place and preserve the last visible value when an external script fails.',
    before: `      const matTintNum = (node, idx, dflt) => {
        const raw = node && typeof node === "object" && "value" in node ? node.value : node;
        if (raw === void 0 || raw === null) return dflt;`,
    after: `      const matTintNum = (node, idx, dflt, layer, key) => {
        let raw = node && typeof node === "object" && "value" in node ? node.value : node;
        if (resourceScriptRuntime && node && typeof node === "object" && typeof node.script === "string") {
          const evaluated = resourceScriptRuntime.value(node, {
            consumer: layer,
            layer,
            slot: "tint",
            key,
            kind: "tint",
            target: "constantshadervalues." + key
          }, resourceScriptFrame);
          if (evaluated === RESOURCE_SCRIPT_UNAVAILABLE) return void 0;
          raw = evaluated && typeof evaluated === "object" && "value" in evaluated ? evaluated.value : evaluated;
        }
        if (raw === void 0 || raw === null) return dflt;`,
  },
  {
    id: 'resource-script-tint-atomic-write',
    reason: 'Apply one coherent tint result only when every authored component evaluated successfully.',
    before: `        const tr = matTintNum(mt.color, 0, 1);
        const tg = matTintNum(mt.color, 1, 1);
        const tb = matTintNum(mt.color, 2, 1);
        const tBright = matTintNum(mt.brightness, 0, 1);
        const tAlpha = matTintNum(mt.alpha, 0, 1);`,
    after: `        const tr = matTintNum(mt.color, 0, 1, layer, "Color");
        const tg = matTintNum(mt.color, 1, 1, layer, "Color");
        const tb = matTintNum(mt.color, 2, 1, layer, "Color");
        const tBright = matTintNum(mt.brightness, 0, 1, layer, "Brightness");
        const tAlpha = matTintNum(mt.alpha, 0, 1, layer, "Alpha");
        if ([tr, tg, tb, tBright, tAlpha].some(value => value === void 0)) return;`,
  },
  {
    id: 'resource-script-issue-source',
    reason: 'Include the validated engine-owned source descriptor in issue identity and public records.',
    before: `      const noteScriptIssue = (layer, target, e, phase) => {
        const message = String(e?.message || e).slice(0, 200);
        const ph = typeof phase === "string" ? phase : "update";
        const layerId = typeof layer?.id === "number" ? layer.id : null;
        const key = \`${'${layerId}'}|${'${target}'}|${'${ph}'}|${'${message}'}\`;`,
    after: `      const noteScriptIssue = (layer, target, e, phase, source = null) => {
        const message = String(e?.message || e).slice(0, 200);
        const ph = typeof phase === "string" ? phase : "update";
        const layerId = typeof layer?.id === "number" ? layer.id : null;
        const sourceKey = source ? source.path + "|" + source.sha256 + "|" + JSON.stringify(source.pointer) + "|" + source.text : "";
        const key = \`${'${layerId}'}|${'${target}'}|${'${ph}'}|${'${message}'}|${'${sourceKey}'}\`;`,
  },
  {
    id: 'resource-script-issue-record-source',
    reason: 'Preserve the optional eighth issue field without changing legacy inline records.',
    before: `            message,
            line: wtext.scriptErrorLine(e),
            count: 1
          });`,
    after: `            message,
            line: wtext.scriptErrorLine(e),
            count: 1,
            ...(source ? { source } : {})
          });`,
  },
  {
    id: 'resource-script-particle-origin',
    reason: 'Capture each exact particle document before compiling emitters or child overrides.',
    before: `        const model = JSON.parse(readText(modelEntry));
        const ps = new particles.ParticleSystem(renderer.gl, model, override, layer);`,
    after: `        const model = JSON.parse(readText(modelEntry));
        resourceOrigins.capture(particlePath, modelEntry, model, "particle");
        const ps = new particles.ParticleSystem(renderer.gl, model, override, layer);`,
  },
  {
    id: 'resource-script-particle-frame',
    reason: 'Apply typed child overrides, emitter rates and particle material constants before advancing the existing pool.',
    before: '          for (const ps of particleSystems) ps.advance(pdt, audioSim.enabled ? activeAudioSnapshot() : null);',
    after: `          for (const ps of particleSystems) {
            applyResourceParticleScripts(ps);
            ps.advance(pdt, audioSim.enabled ? activeAudioSnapshot() : null);
          }`,
  },
  {
    id: 'resource-script-runtime-mount',
    reason: 'Construct one owner-scoped runtime with the same scene environment and lifecycle hooks as inline constants.',
    before: '        renderer.setConstantScriptRuntime?.(evalObjectScript2, {',
    after: `        resourceScriptRuntime = createResourceScriptRuntime({
          origins: resourceOrigins,
          evaluate: evalObjectScript2,
          scripts: !scriptsOff,
          environment: ({ layer }) => ({
            canvasSize: { width: objProjW, height: objProjH },
            screenResolution: resourceScriptFrame.screenResolution,
            timeOfDay: resourceScriptFrame.timeOfDay,
            userProperties: objUserProps,
            audioViews,
            inputView,
            layer,
            ...timerOpts,
            ...sceneApi,
            shared: textShared,
            storage: sceneStorage
          }),
          onIssue: ({ layer, target, error, phase, source }) => {
            noteScriptIssue(layer, target, error, phase, source);
            reportDiag(rt, cfg, \`resource script '${'${source?.path ?? target}'}' failed: ${'${String(error?.message || error).slice(0, 100)}'}\`, "warn");
          },
          onSandbox: ({ sandbox, layer, read, accept }) => {
            if (sandbox.hasMediaHook) registerMediaHook(sandbox);
            registerResizeHook(sandbox);
            if (sandbox.hasAnimEventHook) registerAnimEventSink(layer, { sandbox, kind: "resource", read, accept });
          },
          onDispose: (sandbox) => {
            for (let i = mediaHooks.length - 1; i >= 0; i--) if (mediaHooks[i] === sandbox) mediaHooks.splice(i, 1);
            resizeHooks.delete(sandbox);
            for (const [layer, sinks] of animEventSinks) {
              const kept = sinks.filter(item => item.sandbox !== sandbox);
              if (kept.length) animEventSinks.set(layer, kept);
              else animEventSinks.delete(layer);
            }
          }
        });
        renderer.setResourceScriptRuntime?.(resourceScriptRuntime);
        applyResourceParticleScripts = (ps) => {
          const override = ps.override || {};
          for (const [key, wrapper] of Object.entries(override)) {
            if (!wrapper || typeof wrapper !== "object" || !resourceOrigins.owns(wrapper)) continue;
            const value = resourceScriptRuntime.value(wrapper, {
              consumer: ps,
              layer: ps.layer,
              slot: "instanceoverride",
              key,
              kind: "particle",
              target: "instanceoverride." + key
            }, resourceScriptFrame);
            if (value === RESOURCE_SCRIPT_UNAVAILABLE) continue;
            if (key === "colorn") ps.setColorOverride(String(value).trim().split(/[\\s,]+/).map(Number));
            else ps.setOverrideValue(key, value);
          }
          const emitters = ps.model?.emitter || [];
          for (let index = 0; index < emitters.length; index++) {
            const wrapper = emitters[index]?.rate;
            if (!wrapper || typeof wrapper !== "object" || !resourceOrigins.owns(wrapper)) continue;
            const value = resourceScriptRuntime.value(wrapper, {
              consumer: ps,
              layer: ps.layer,
              slot: "emitter[" + index + "]",
              key: "rate",
              kind: "particle",
              target: "emitter[" + index + "].rate"
            }, resourceScriptFrame);
            if (value !== RESOURCE_SCRIPT_UNAVAILABLE && Number.isFinite(Number(value)) && ps.emitters?.[index]) ps.emitters[index].rate = Number(value);
          }
          const constants = ps.matShader?.constants || ps.material?.passes?.[0]?.constantshadervalues || {};
          const evaluated = resourceScriptRuntime.constants(constants, {
            consumer: ps,
            layer: ps.layer,
            slot: "particle-material",
            kind: "particle",
            target: "constantshadervalues"
          }, resourceScriptFrame);
          setResourceParticleConstants(ps, evaluated);
          const scalar = (key) => {
            const value = evaluated[key];
            if (value === RESOURCE_SCRIPT_UNAVAILABLE) return void 0;
            const raw = value && typeof value === "object" && "value" in value ? value.value : value;
            const number = Number(raw);
            return Number.isFinite(number) ? number : void 0;
          };
          const overbright = scalar("ui_editor_properties_overbright");
          if (overbright !== void 0) ps.overbright = Math.max(0, overbright);
          const refract = scalar("ui_editor_properties_refract_amount");
          if (refract !== void 0) ps.refractAmount = Math.min(1, Math.max(-1, refract));
        };
        {
          const previousResourceCleanup = particleCleanup;
          particleCleanup = () => {
            resourceScriptRuntime?.dispose();
            previousResourceCleanup?.();
          };
        }
        renderer.setConstantScriptRuntime?.(evalObjectScript2, {`,
  },
  {
    id: 'resource-script-animation-events',
    reason: 'Let authenticated resource constants consume animation events through their typed state.',
    before: '                } else if (sink.kind === "const") {\n                  const ret = sb.callAnimationEvent(ev, sb.__lastConstValue);',
    after: `                } else if (sink.kind === "resource") {
                  sink.accept(sb.callAnimationEvent(ev, sink.read()));
                } else if (sink.kind === "const") {
                  const ret = sb.callAnimationEvent(ev, sb.__lastConstValue);`,
  },
  {
    id: 'resource-script-frame-context',
    reason: 'Update non-renderer sinks with the same frame clock and screen state before drawing.',
    before: `          particleClock.dt = clockDt;
          particleClock.t = t;
          let visibilityDirty = false;`,
    after: `          particleClock.dt = clockDt;
          particleClock.t = t;
          resourceScriptFrame.runtime = t;
          resourceScriptFrame.frametime = animDt;
          resourceScriptFrame.timeOfDay = timeOfDayValue;
          resourceScriptFrame.screenResolution = { x: c.clientWidth || c.width, y: c.clientHeight || c.height };
          for (const layer of scene.layers) if (layer.matTint) applyBuiltinMatTint(layer);
          let visibilityDirty = false;`,
  },
  {
    id: 'resource-script-live-user-properties',
    reason: 'Deliver current user properties to every owned resource sandbox before the next frame.',
    before: '        renderer.applyConstUserProperties?.(changed);',
    after: `        renderer.applyConstUserProperties?.(changed);
        resourceScriptRuntime?.applyUserProperties(changed);`,
  },
  {
    id: 'resource-script-layer-disposal',
    reason: 'Dispose every external sandbox and timer owned by removed layer consumers.',
    before: '      const teardownLayer = (ids, effects) => {\n        const deadSandboxes = /* @__PURE__ */ new Set();',
    after: `      const teardownLayer = (ids, effects) => {
        resourceScriptRuntime?.disposeLayers(ids);
        const deadSandboxes = /* @__PURE__ */ new Set();`,
  },
];

export function patchSceneResourceScripts(original) {
  if (typeof original !== 'string') throw new TypeError('Pinned renderer source must be text');
  let source = original;
  for (const edit of edits) {
    const expected = edit.matches ?? 1;
    const parts = source.split(edit.before);
    const actual = parts.length - 1;
    if (actual !== expected) throw new Error(`Pinned resource script patch ${edit.id}: expected ${expected} anchor matches, found ${actual}`);
    source = parts.join(edit.after);
  }
  return { source, patches: edits.map(({ id, reason, matches = 1 }) => ({ id, reason, matches })) };
}
