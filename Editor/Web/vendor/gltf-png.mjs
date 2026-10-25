// Derived from MIT WebWallGL editor/gltf.ts at 197abe54266c31d346cebc314e49a26b70c960cc.
// License: Editor/ThirdParty/WebWallGL-MDL-LICENSE. Source selection recorded in gltf-provenance.json.
const enc = new TextEncoder();
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 3988292384 ^ c >>> 1 : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(bytes) {
  let c = 4294967295;
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 255] ^ c >>> 8;
  return (c ^ 4294967295) >>> 0;
}
const toSrgb8 = (v) => {
  const c = Math.min(1, Math.max(0, v));
  return Math.round(255 * (c <= 31308e-7 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055));
};
function solidPng(factor, size = 4) {
  const rgba = [toSrgb8(factor[0] ?? 1), toSrgb8(factor[1] ?? 1), toSrgb8(factor[2] ?? 1), Math.round(255 * Math.min(1, Math.max(0, factor[3] ?? 1)))];
  const px = new Uint8Array(size * size * 4);
  for (let i = 0; i < size * size; i++) px.set(rgba, i * 4);
  return encodePng(size, size, px);
}
function encodePng(width, height, rgba) {
  const row = 1 + width * 4;
  const raw = new Uint8Array(height * row);
  for (let y = 0; y < height; y++) raw.set(rgba.subarray(y * width * 4, (y + 1) * width * 4), y * row + 1);
  let a = 1;
  let b = 0;
  for (let i = 0; i < raw.length; i++) {
    a += raw[i];
    if (a >= 65521) a -= 65521;
    b += a;
    if (b >= 65521) b -= 65521;
  }
  const blocks = Math.max(1, Math.ceil(raw.length / 65535));
  const z = new Uint8Array(2 + blocks * 5 + raw.length + 4);
  z.set([120, 1]);
  let o = 2;
  for (let k = 0; k < blocks; k++) {
    const part = raw.subarray(k * 65535, Math.min(raw.length, (k + 1) * 65535));
    const n = part.length;
    z.set([k === blocks - 1 ? 1 : 0, n & 255, n >> 8, ~n & 255, ~n >> 8 & 255], o);
    z.set(part, o + 5);
    o += 5 + n;
  }
  new DataView(z.buffer).setUint32(o, (b << 16 | a) >>> 0);
  const chunk = (type, body) => {
    const out2 = new Uint8Array(12 + body.length);
    const dv = new DataView(out2.buffer);
    dv.setUint32(0, body.length);
    out2.set(enc.encode(type), 4);
    out2.set(body, 8);
    dv.setUint32(8 + body.length, crc32(out2.subarray(4, 8 + body.length)));
    return out2;
  };
  const ihdr = new Uint8Array(13);
  const hv = new DataView(ihdr.buffer);
  hv.setUint32(0, width);
  hv.setUint32(4, height);
  ihdr.set([8, 6, 0, 0, 0], 8);
  const parts = [Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10), chunk("IHDR", ihdr), chunk("IDAT", z), chunk("IEND", new Uint8Array(0))];
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let w = 0;
  for (const p of parts) out.set(p, w), w += p.length;
  return out;
}
export {
  encodePng,
  solidPng
};
