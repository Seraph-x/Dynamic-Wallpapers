import { inspectSceneScript, prepareSceneScript, applySceneScript } from './script-api.mjs';

// Snapshot dictionary order may change across the native bridge; array order and
// length still identify a different document revision.
function equivalent(left, right) {
  const pending = [[left,right]];
  while (pending.length) {
    const [a,b] = pending.pop();
    if (Object.is(a,b)) continue;
    if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return false;
    if (Array.isArray(a) && a.length !== b.length) return false;
    const keys = Object.keys(a);
    if (keys.length !== Object.keys(b).length || keys.some(key => !Object.hasOwn(b,key))) return false;
    for (const key of keys) pending.push([a[key],b[key]]);
  }
  return true;
}

function snapshotOf(document) {
  if (!document || typeof document.snapshot !== 'function' || typeof document.script !== 'function') throw new Error('Expected a SceneDocument');
  return document.snapshot();
}

function validateSource(source) {
  if (typeof source !== 'string') throw new Error('Script source must be a string');
  if (source.includes('\0')) throw new Error('Script source cannot contain NUL');
  if (/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(source)) throw new Error('Script source must contain valid Unicode');
}

/** A source draft has no history until its checked edit is explicitly applied. */
export class ScriptDraft {
  #document; #snapshot; #selection; #state; #source;
  #input = false; #proposal = null; #diagnostics = [];

  constructor(document, selection) {
    this.#selection = structuredClone(selection);
    this.revert(document);
  }

  get state() { return structuredClone(this.#state); }
  get source() { return this.#source; }
  get dirty() {
    return this.#source !== (typeof this.#state.source === 'string' ? this.#state.source : '') ||
      (this.#input && this.#state.kind === 'constant');
  }
  get diagnostics() { return structuredClone(this.#diagnostics); }

  #assertEditable() {
    if (!this.#state.editable) throw new Error(this.#state.reason);
  }

  #assertCurrent(document) {
    const current = snapshotOf(document);
    if (document !== this.#document || !equivalent(current,this.#snapshot)) throw new Error('Script draft document changed; the draft is stale');
  }

  setSource(source) {
    this.#assertEditable();
    validateSource(source);
    this.#source = source;
    this.#input = true;
    this.#proposal = null;
    this.#diagnostics = [];
  }

  check() {
    this.#assertEditable();
    this.#assertCurrent(this.#document);
    if (!this.#proposal) {
      try {
        this.#proposal = prepareSceneScript(this.#document,{...this.#selection,type:'set',source:this.#source});
        this.#diagnostics = this.#proposal.diagnostics;
      } catch (error) {
        if (error.name === 'SceneScriptSyntaxError') this.#diagnostics = [{level:'error',code:'SYNTAX',message:error.message,line:error.line}];
        throw error;
      }
    }
    return structuredClone(this.#proposal.check);
  }

  /** Call inside editor.change so runtime capture and canonical history agree. */
  apply(document) {
    this.#assertEditable();
    this.#assertCurrent(document);
    if (!this.dirty) return false;
    this.check();
    const proposal = this.#proposal;
    applySceneScript(document,proposal);
    this.revert(document);
    this.#diagnostics = proposal.diagnostics;
    return true;
  }

  remove(document) {
    this.#assertEditable();
    this.#assertCurrent(document);
    const changed = this.#state.kind === 'script';
    if (changed) applySceneScript(document,prepareSceneScript(document,{...this.#selection,type:'remove'}));
    this.revert(document);
    return changed;
  }

  /** Restore local input without rebasing onto an external document revision. */
  restoreInput() {
    this.#source=typeof this.#state.source==='string'?this.#state.source:'';
    this.#input=false;this.#proposal=null;this.#diagnostics=[];
  }

  /** Explicit recovery may adopt a replacement document after a conflict. */
  revert(document) {
    const snapshot = snapshotOf(document);
    const state = inspectSceneScript(snapshot.scene,this.#selection);
    this.#document = document;
    this.#snapshot = snapshot;
    this.#state = state;
    this.#source = typeof state.source === 'string' ? state.source : '';
    this.#input = false;
    this.#proposal = null;
    this.#diagnostics = [];
  }
}
