// Derived from MIT WebWallGL editor/gltf.ts at 197abe54266c31d346cebc314e49a26b70c960cc.
// License: Editor/ThirdParty/WebWallGL-MDL-LICENSE. Source selection recorded in gltf-provenance.json.
const ident = () => Float64Array.of(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
function mul(a, b) {
  const o = new Float64Array(16);
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      let s = 0;
      for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
      o[c * 4 + r] = s;
    }
  }
  return o;
}
function invert(m) {
  const a = Array.from(m);
  const inv = Array.from(ident());
  for (let c = 0; c < 4; c++) {
    let piv = c;
    for (let r = c + 1; r < 4; r++) if (Math.abs(a[c * 4 + r]) > Math.abs(a[c * 4 + piv])) piv = r;
    if (Math.abs(a[c * 4 + piv]) < 1e-12) return null;
    if (piv !== c) {
      for (let k = 0; k < 4; k++) {
        [a[k * 4 + c], a[k * 4 + piv]] = [a[k * 4 + piv], a[k * 4 + c]];
        [inv[k * 4 + c], inv[k * 4 + piv]] = [inv[k * 4 + piv], inv[k * 4 + c]];
      }
    }
    const d = a[c * 4 + c];
    for (let k = 0; k < 4; k++) {
      a[k * 4 + c] /= d;
      inv[k * 4 + c] /= d;
    }
    for (let r = 0; r < 4; r++) {
      if (r === c) continue;
      const f = a[c * 4 + r];
      if (!f) continue;
      for (let k = 0; k < 4; k++) {
        a[k * 4 + r] -= f * a[k * 4 + c];
        inv[k * 4 + r] -= f * inv[k * 4 + c];
      }
    }
  }
  return Float64Array.from(inv);
}
function composeTRSQ(t, q, s) {
  const [x, y, z, w] = q;
  const xx = x * x, yy = y * y, zz = z * z, xy = x * y, xz = x * z, yz = y * z, wx = w * x, wy = w * y, wz = w * z;
  return Float64Array.of(
    (1 - 2 * (yy + zz)) * s[0],
    2 * (xy + wz) * s[0],
    2 * (xz - wy) * s[0],
    0,
    2 * (xy - wz) * s[1],
    (1 - 2 * (xx + zz)) * s[1],
    2 * (yz + wx) * s[1],
    0,
    2 * (xz + wy) * s[2],
    2 * (yz - wx) * s[2],
    (1 - 2 * (xx + yy)) * s[2],
    0,
    t[0],
    t[1],
    t[2],
    1
  );
}
function decompose(m) {
  let sx = Math.hypot(m[0], m[1], m[2]);
  const sy = Math.hypot(m[4], m[5], m[6]);
  const sz = Math.hypot(m[8], m[9], m[10]);
  const det = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[4] * (m[1] * m[10] - m[2] * m[9]) + m[8] * (m[1] * m[6] - m[2] * m[5]);
  if (det < 0) sx = -sx;
  const r = [m[0] / (sx || 1), m[1] / (sx || 1), m[2] / (sx || 1), m[4] / (sy || 1), m[5] / (sy || 1), m[6] / (sy || 1), m[8] / (sz || 1), m[9] / (sz || 1), m[10] / (sz || 1)];
  const [m00, m10, m20, m01, m11, m21, m02, m12, m22] = r;
  const tr = m00 + m11 + m22;
  let q;
  if (tr > 0) {
    const S = Math.sqrt(tr + 1) * 2;
    q = [(m21 - m12) / S, (m02 - m20) / S, (m10 - m01) / S, 0.25 * S];
  } else if (m00 > m11 && m00 > m22) {
    const S = Math.sqrt(1 + m00 - m11 - m22) * 2;
    q = [0.25 * S, (m01 + m10) / S, (m02 + m20) / S, (m21 - m12) / S];
  } else if (m11 > m22) {
    const S = Math.sqrt(1 + m11 - m00 - m22) * 2;
    q = [(m01 + m10) / S, 0.25 * S, (m12 + m21) / S, (m02 - m20) / S];
  } else {
    const S = Math.sqrt(1 + m22 - m00 - m11) * 2;
    q = [(m02 + m20) / S, (m12 + m21) / S, 0.25 * S, (m10 - m01) / S];
  }
  return { t: [m[12], m[13], m[14]], r: normQ(q), s: [sx || 1, sy || 1, sz || 1] };
}
function normQ(q) {
  const l = Math.hypot(q[0], q[1], q[2], q[3]) || 1;
  return [q[0] / l, q[1] / l, q[2] / l, q[3] / l];
}
function slerp(a, b, t) {
  let d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
  const bb = [b[0], b[1], b[2], b[3]];
  if (d < 0) {
    d = -d;
    for (let k = 0; k < 4; k++) bb[k] = -bb[k];
  }
  if (d > 0.9995) return normQ([0, 1, 2, 3].map((k) => a[k] + (bb[k] - a[k]) * t));
  const th = Math.acos(Math.min(1, d));
  const s = Math.sin(th);
  const wa = Math.sin((1 - t) * th) / s;
  const wb = Math.sin(t * th) / s;
  return normQ([0, 1, 2, 3].map((k) => a[k] * wa + bb[k] * wb));
}
const wrapNear = (v, ref) => v + 2 * Math.PI * Math.round((ref - v) / (2 * Math.PI));
function quatToEuler(q, prev) {
  const [x, y, z, w] = q;
  const r00 = 1 - 2 * (y * y + z * z);
  const r10 = 2 * (x * y + w * z);
  const r20 = 2 * (x * z - w * y);
  const r21 = 2 * (y * z + w * x);
  const r22 = 1 - 2 * (x * x + y * y);
  const r01 = 2 * (x * y - w * z);
  const r11 = 1 - 2 * (x * x + z * z);
  const sy = Math.max(-1, Math.min(1, -r20));
  const ry = Math.asin(sy);
  let cands;
  if (Math.sqrt(r21 * r21 + r22 * r22) > 1e-6) {
    const rx = Math.atan2(r21, r22);
    const rz = Math.atan2(r10, r00);
    cands = [
      [rx, ry, rz],
      [rx + Math.PI, Math.PI - ry, rz + Math.PI]
    ];
  } else {
    const rz = prev ? prev[2] : 0;
    const rx = sy > 0 ? Math.atan2(r01, r11) + rz : Math.atan2(-r01, r11) - rz;
    cands = [[rx, sy > 0 ? Math.PI / 2 : -Math.PI / 2, rz]];
  }
  if (!prev) return cands[0].map((v) => Math.atan2(Math.sin(v), Math.cos(v)));
  let best = cands[0];
  let bd = Infinity;
  for (const c of cands) {
    const u = c.map((v, k) => wrapNear(v, prev[k]));
    const d = u.reduce((s, v, k) => s + (v - prev[k]) ** 2, 0);
    if (d < bd) {
      bd = d;
      best = u;
    }
  }
  return best;
}
function restTRS(n) {
  if (Array.isArray(n.matrix) && n.matrix.length === 16) return decompose(n.matrix);
  return {
    t: (n.translation ?? [0, 0, 0]).slice(0, 3),
    r: normQ(n.rotation ?? [0, 0, 0, 1]),
    s: (n.scale ?? [1, 1, 1]).slice(0, 3)
  };
}
function restLocal(n) {
  if (Array.isArray(n.matrix) && n.matrix.length === 16) return Float64Array.from(n.matrix);
  const r = restTRS(n);
  return composeTRSQ(r.t, r.r, r.s);
}
function sampleAt(s, t, quat) {
  const n = s.times.length;
  const cubic = s.interp === "CUBICSPLINE";
  const val = (k2) => {
    const o = cubic ? (k2 * 3 + 1) * s.size : k2 * s.size;
    return Array.from(s.values.subarray(o, o + s.size));
  };
  if (n === 0) return [];
  if (t <= s.times[0] || n === 1) return val(0);
  if (t >= s.times[n - 1]) return val(n - 1);
  let lo = 0, hi = n - 1;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if (t >= s.times[mid]) lo = mid;
    else hi = mid;
  }
  const k = lo;
  const t0 = s.times[k];
  const dt = s.times[k + 1] - t0;
  const u = dt > 0 ? (t - t0) / dt : 0;
  if (s.interp === "STEP") return val(k);
  if (cubic) {
    const p0 = val(k);
    const p1 = val(k + 1);
    const m0 = Array.from(s.values.subarray((k * 3 + 2) * s.size, (k * 3 + 3) * s.size));
    const m1 = Array.from(s.values.subarray((k + 1) * 3 * s.size, ((k + 1) * 3 + 1) * s.size));
    const u2 = u * u;
    const u3 = u2 * u;
    const out = p0.map((_, i) => (2 * u3 - 3 * u2 + 1) * p0[i] + (u3 - 2 * u2 + u) * dt * m0[i] + (-2 * u3 + 3 * u2) * p1[i] + (u3 - u2) * dt * m1[i]);
    return quat ? normQ(out) : out;
  }
  const a = val(k);
  const b = val(k + 1);
  if (quat) return slerp(a, b, u);
  return a.map((v, i) => v + (b[i] - v) * u);
}
export {
  composeTRSQ,
  decompose,
  ident,
  invert,
  mul,
  quatToEuler,
  sampleAt
};
