export class TimelineClock {
  #editor; #queue=Promise.resolve(); #range={start:0,end:5,loop:false}; #wrapping;
  constructor(editor) { this.#editor=editor; }
  get time() { return this.#editor.controls?.time ?? 0; }
  get rangeValue() { return {...this.#range}; }
  range(value) {
    if (!Number.isFinite(value.start) || !Number.isFinite(value.end) || value.start < 0 || value.end <= value.start || typeof value.loop !== 'boolean') throw new Error('Invalid preview range');
    this.#range={...value};
  }
  seek(time) {
    if (!Number.isFinite(time) || time < 0) return Promise.reject(new Error('Invalid timeline time'));
    this.#editor.setPlaying(false);
    return this.#seek(time);
  }
  #seek(time) { return this.#enqueue(()=>this.#editor.seek(time)); }
  #enqueue(action) {
    const operation=this.#queue.then(action);
    this.#queue=operation.catch(()=>{}); // The returned operation exposes every failure to its caller.
    return operation;
  }
  step(frames,fps) {
    if (!Number.isFinite(frames) || !Number.isFinite(fps) || fps <= 0) return Promise.reject(new Error('Invalid frame step'));
    this.#editor.setPlaying(false);
    return this.#enqueue(()=>this.#editor.seek(Math.max(0,this.time+frames/fps)));
  }
  async tick() {
    const {start,end,loop}=this.#range;
    if (!loop || !this.#editor.playing || this.#editor.frozen || this.#wrapping || (this.time >= start && this.time < end)) return;
    const time=this.time < start ? start : start+(this.time-end)%(end-start);
    this.#wrapping=this.#seek(time);
    try { await this.#wrapping; } finally { this.#wrapping=undefined; }
  }
}
