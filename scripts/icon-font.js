// Builds app/assets/fonts/CawIcons.ttf, C.A.W's own line icons (the bird-family hints and the quill), from strokes drawn on a 24-unit grid; run `node scripts/icon-font.js` after changing a glyph.
'use strict';
const fs = require('fs');
const path = require('path');

const EM = 960; // units per em; the 24-unit grid is 40 units a step
const K = EM / 24;
const W = 1.9; // stroke width in grid units

// --- drawing: polylines of [x, y] in grid units (y down), sampled from curves ---
const quad = (a, c, b, n = 14) => Array.from({ length: n + 1 }, (_, i) => {
  const t = i / n, u = 1 - t;
  return [u * u * a[0] + 2 * u * t * c[0] + t * t * b[0], u * u * a[1] + 2 * u * t * c[1] + t * t * b[1]];
});
const cubic = (a, c1, c2, b, n = 18) => Array.from({ length: n + 1 }, (_, i) => {
  const t = i / n, u = 1 - t;
  const f = (k) => u * u * u * a[k] + 3 * u * u * t * c1[k] + 3 * u * t * t * c2[k] + t * t * t * b[k];
  return [f(0), f(1)];
});
const arc = (cx, cy, r, from, to, n = 16) => Array.from({ length: n + 1 }, (_, i) => {
  const a = (from + (to - from) * i / n) * Math.PI / 180;
  return [cx + r * Math.cos(a), cy + r * Math.sin(a)];
});

// Each glyph: its code point and its strokes.
const GLYPHS = [
  // Roost (reverb, the space family): a tail of two arcs over a branch with a twig.
  { name: 'roost', code: 0xe001, strokes: [
    [[3, 19], [21, 16]], [[15, 17], [18, 13.5]], arc(11, 15.5, 3.2, 200, 340), arc(11, 15.5, 7, 205, 335)] },
  // Talon (dynamics): a compressor's transfer curve whose end hooks down like a claw.
  { name: 'talon', code: 0xe002, strokes: [
    [[3, 21], [10, 14]], [...quad([10, 14], [13, 10.5], [18, 9.5]), ...quad([18, 9.5], [21.5, 9], [20.5, 13.5]).slice(1)],
    [[3, 4], [3, 21], [21, 21]]] },
  // Plume (EQ): a feather whose vane edge rises like a bell curve.
  { name: 'plume', code: 0xe003, strokes: [
    quad([4, 21], [10, 14], [19, 4]), cubic([19, 4], [10, 4], [5, 11], [8, 16.5]), cubic([19, 4], [20, 12], [14, 17], [8, 16.5]),
    [[11, 13], [7.5, 11]], [[14, 10], [16.5, 12.5]]] },
  // Nest (racks): a woven bowl, its weave like a rack's rows.
  { name: 'nest', code: 0xe004, strokes: [
    [...arc(12, 9, 9, 0, 180)], [[3, 9], [21, 9]], quad([5, 13], [12, 15.5], [19, 13]), quad([8, 16.5], [12, 18], [16, 16.5])] },
  // The quill: the drag-to-modulate handle.
  { name: 'quill', code: 0xe005, strokes: [
    [[4, 20], [20, 4]], cubic([20, 4], [12, 4], [8, 9], [9.5, 14.5]), cubic([20, 4], [20, 12], [15, 16], [9.5, 14.5]),
    [[4, 20], [3, 21]]] },
];

// --- strokes to filled contours: a quad per segment and a disc per point, all one way round (non-zero fill) ---
function contoursOf(strokes) {
  const out = [];
  const r = W / 2;
  const wind = (pts) => {
    let a = 0;
    for (let i = 0; i < pts.length; i++) { const p = pts[i], q = pts[(i + 1) % pts.length]; a += p[0] * q[1] - q[0] * p[1]; }
    return a;
  };
  // Font space is y up; TrueType outer contours run clockwise there (negative area in y-up maths).
  const push = (pts) => {
    const f = pts.map(([x, y]) => [Math.round(x * K), Math.round(EM - y * K)]);
    if (wind(f) > 0) f.reverse();
    out.push(f);
  };
  for (const s of strokes) {
    for (let i = 0; i + 1 < s.length; i++) {
      const [ax, ay] = s[i], [bx, by] = s[i + 1];
      const dx = bx - ax, dy = by - ay, len = Math.hypot(dx, dy);
      if (len < 1e-6) continue;
      const nx = -dy / len * r, ny = dx / len * r;
      push([[ax + nx, ay + ny], [bx + nx, by + ny], [bx - nx, by - ny], [ax - nx, ay - ny]]);
    }
    for (const [x, y] of s) push(Array.from({ length: 12 }, (_, i) => [x + r * Math.cos(i * Math.PI / 6), y + r * Math.sin(i * Math.PI / 6)]));
  }
  return out;
}

// --- a minimal TrueType file ---
function u16(v) { const b = Buffer.alloc(2); b.writeUInt16BE(v & 0xffff); return b; }
function i16(v) { const b = Buffer.alloc(2); b.writeInt16BE(v); return b; }
function u32(v) { const b = Buffer.alloc(4); b.writeUInt32BE(v >>> 0); return b; }
const cat = (...p) => Buffer.concat(p);

function glyf(contours) {
  if (!contours.length) return Buffer.alloc(0);
  const pts = contours.flat();
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const parts = [i16(contours.length), i16(Math.min(...xs)), i16(Math.min(...ys)), i16(Math.max(...xs)), i16(Math.max(...ys))];
  let end = -1;
  for (const c of contours) { end += c.length; parts.push(u16(end)); }
  parts.push(u16(0)); // no instructions
  parts.push(Buffer.alloc(pts.length, 1)); // every point on the curve, 16-bit deltas
  let px = 0, py = 0;
  const dx = [], dy = [];
  for (const [x, y] of pts) { dx.push(i16(x - px)); dy.push(i16(y - py)); px = x; py = y; }
  const b = cat(...parts, ...dx, ...dy);
  return b.length % 4 ? cat(b, Buffer.alloc(4 - (b.length % 4))) : b;
}

function checksum(buf) {
  const b = buf.length % 4 ? cat(buf, Buffer.alloc(4 - (buf.length % 4))) : buf;
  let s = 0;
  for (let i = 0; i < b.length; i += 4) s = (s + b.readUInt32BE(i)) >>> 0;
  return s;
}

function build() {
  const glyphs = [Buffer.alloc(0), ...GLYPHS.map((g) => glyf(contoursOf(g.strokes)))];
  const loca = [];
  let off = 0;
  for (const g of glyphs) { loca.push(u32(off)); off += g.length; }
  loca.push(u32(off));
  const n = glyphs.length;
  let maxPts = 0, maxContours = 0;
  for (const g of GLYPHS) { const c = contoursOf(g.strokes); maxContours = Math.max(maxContours, c.length); maxPts = Math.max(maxPts, c.flat().length); }
  const head = cat(u32(0x00010000), u32(0x00010000), u32(0), u32(0x5f0f3cf5), u16(0x000b), u16(EM),
    Buffer.alloc(16), i16(0), i16(0), i16(EM), i16(EM), u16(0), u16(8), i16(2), i16(1), i16(0));
  const hhea = cat(u32(0x00010000), i16(EM), i16(0), i16(0), u16(EM), i16(0), i16(0), i16(EM), i16(1), i16(0), i16(0),
    Buffer.alloc(8), i16(0), u16(n));
  const maxp = cat(u32(0x00010000), u16(n), u16(maxPts), u16(maxContours), u16(0), u16(0), u16(2), u16(0), u16(0),
    u16(0), u16(0), u16(0), u16(0), u16(0), u16(0));
  const hmtx = cat(...glyphs.map(() => cat(u16(EM), i16(0))));
  // cmap format 4: one segment per code point, then the end segment.
  const codes = GLYPHS.map((g, i) => [g.code, i + 1]);
  const segs = codes.length + 1;
  const ends = [...codes.map((c) => c[0]), 0xffff], starts = [...codes.map((c) => c[0]), 0xffff];
  const deltas = [...codes.map(([c, gid]) => (gid - c) & 0xffff), 1];
  const sub = cat(u16(4), u16(16 + segs * 8), u16(0), u16(segs * 2), u16(2), u16(0), u16(segs * 2 - 2),
    ...ends.map(u16), u16(0), ...starts.map(u16), ...deltas.map(u16), ...ends.map(() => u16(0)));
  const cmap = cat(u16(0), u16(1), u16(3), u16(1), u32(12), sub);
  const strings = [[1, 'CawIcons'], [2, 'Regular'], [4, 'CawIcons'], [6, 'CawIcons']];
  const enc = strings.map(([id, s]) => [id, Buffer.from(s, 'utf16le').swap16()]);
  let so = 0;
  const recs = enc.map(([id, b]) => { const r = cat(u16(3), u16(1), u16(0x409), u16(id), u16(b.length), u16(so)); so += b.length; return r; });
  const name = cat(u16(0), u16(enc.length), u16(6 + 12 * enc.length), ...recs, ...enc.map((e) => e[1]));
  const os2 = cat(u16(4), i16(EM), u16(400), u16(5), u16(0), ...Array(10).fill(i16(0)), i16(0), Buffer.alloc(10),
    Buffer.alloc(16), Buffer.from('CAW '), u16(0x40), u16(0xe001), u16(0xe005), i16(EM), i16(0), i16(0), u16(EM), u16(0),
    u32(1), u32(0), i16(0), i16(0), u16(0), u16(0x20), u16(0));
  const post = cat(u32(0x00030000), u32(0), i16(0), i16(0), u32(1), Buffer.alloc(16));
  const tables = { 'OS/2': os2, cmap, glyf: cat(...glyphs), head, hhea, hmtx, loca: cat(...loca), maxp, name, post };
  const tags = Object.keys(tables).sort();
  const dir = [];
  let at = 12 + 16 * tags.length;
  const bodies = [];
  for (const t of tags) {
    const b = tables[t];
    dir.push(cat(Buffer.from(t), u32(checksum(b)), u32(at), u32(b.length)));
    const padded = b.length % 4 ? cat(b, Buffer.alloc(4 - (b.length % 4))) : b;
    bodies.push(padded);
    at += padded.length;
  }
  const font = cat(u32(0x00010000), u16(tags.length), u16(128), u16(3), u16(tags.length * 16 - 128), ...dir, ...bodies);
  const headAt = 12 + 16 * tags.length + bodies.slice(0, tags.indexOf('head')).reduce((s, b) => s + b.length, 0);
  font.writeUInt32BE((0xb1b0afba - checksum(font)) >>> 0, headAt + 8);
  return font;
}

const out = path.join(__dirname, '..', 'app', 'assets', 'fonts', 'CawIcons.ttf');
fs.writeFileSync(out, build());
console.log(`PASS icon-font - ${GLYPHS.length} glyphs (${path.relative(process.cwd(), out)})`);
