// Use the actual pinned pure media-source implementation in Node tests. The
// full browser bundle also initializes DOM APIs and belongs in browser tests.
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { runInNewContext } from 'node:vm';
const upstream = await readFile(new URL('./scene-runtime-build/node_modules/webwallgl/webwallgl.mjs', import.meta.url), 'utf8');
if (createHash('sha256').update(upstream).digest('hex') !== 'f838e70347df8205edca5f3fc04dbb7c56b31738b5785b27038d912d5c45a1bc') {
  throw new Error('Media test requires the unmodified pinned WebWallGL entry');
}
const start = upstream.indexOf('class Color {');
const end = upstream.indexOf('const shimSource =', start);
if (start < 0 || end < start) throw new Error('Pinned media-source test anchors are missing');
export const createMediaSource = runInNewContext(`${upstream.slice(start, end)}\ncreateMediaSource`);
