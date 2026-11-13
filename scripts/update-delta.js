// Builds the small-update assets for a release: a manifest (every file in the APK and the Windows zip, with sizes and SHA-256) and patches from the previous build, each checked by applying it before it is published.
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

// ---- The patch format (CAWPATCH v1; read on the device by app/lib/model/updates/patch_format.dart) ----
//
// "CAWPATCH", a version byte (1), then one raw DEFLATE stream holding:
//   varint fileCount
//   per file: varint pathLength, path (UTF-8, '/'-separated, relative), varint newSize, 32-byte new SHA-256,
//             a byte hasBase (1: the ops read a base file, whose 32-byte SHA-256 follows), then ops up to END:
//     0 END
//     1 COPY   varint offset, varint length         (bytes of the base file)
//     2 DATA   varint length, the bytes
//     3 BSDIFF varint baseOffset, varint baseLength, varint newLength, then blocks until newLength bytes are made:
//              varint x, varint y, zigzag varint z, x diff bytes, y extra bytes (bspatch: x bytes of
//              base[pos+i] + diff[i] mod 256, then y extra bytes, then pos += x + z; outside the base range adds 0)
// An APK patch has one file whose base is the installed APK; a Windows patch has one file per changed file, whose
// base (if any) is the installed file at the same path.

const MAGIC = Buffer.from('CAWPATCH', 'ascii');
const VERSION = 1;
const OP = { END: 0, COPY: 1, DATA: 2, BSDIFF: 3 };

class Writer {
  constructor() {
    this.parts = [];
    this.length = 0;
  }
  bytes(b) {
    if (b.length) {
      this.parts.push(Buffer.from(b.buffer, b.byteOffset, b.length));
      this.length += b.length;
    }
  }
  byte(v) {
    this.bytes(Buffer.from([v]));
  }
  varint(n) {
    if (!Number.isSafeInteger(n) || n < 0) throw new Error(`bad varint ${n}`);
    const out = [];
    do {
      let b = n % 128;
      n = Math.floor(n / 128);
      if (n > 0) b |= 0x80;
      out.push(b);
    } while (n > 0);
    this.bytes(Buffer.from(out));
  }
  svarint(n) {
    this.varint(n >= 0 ? n * 2 : -n * 2 - 1);
  }
  done() {
    return Buffer.concat(this.parts, this.length);
  }
}

class Reader {
  constructor(buf) {
    this.buf = buf;
    this.pos = 0;
  }
  need(n) {
    if (this.pos + n > this.buf.length) throw new Error('truncated patch');
  }
  byte() {
    this.need(1);
    return this.buf[this.pos++];
  }
  take(n) {
    this.need(n);
    const b = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return b;
  }
  varint() {
    let n = 0;
    let scale = 1;
    for (let i = 0; i < 8; i++) {
      const b = this.byte();
      n += (b & 0x7f) * scale;
      if (!(b & 0x80)) return n;
      scale *= 128;
    }
    throw new Error('varint too long');
  }
  svarint() {
    const n = this.varint();
    return n % 2 === 0 ? n / 2 : -(n + 1) / 2;
  }
}

const sha = (buf) => crypto.createHash('sha256').update(buf).digest();
const hex = (buf) => buf.toString('hex');

/** Encodes one file's ops. [ops]: {copy:[off,len]} | {data:Buffer} | {bsdiff:{baseOffset,baseLength,newLength,blocks:[{x,y,z,diff,extra}]}} */
function writeOps(w, ops) {
  for (const op of ops) {
    if (op.copy) {
      w.byte(OP.COPY);
      w.varint(op.copy[0]);
      w.varint(op.copy[1]);
    } else if (op.data) {
      w.byte(OP.DATA);
      w.varint(op.data.length);
      w.bytes(op.data);
    } else if (op.bsdiff) {
      const d = op.bsdiff;
      w.byte(OP.BSDIFF);
      w.varint(d.baseOffset);
      w.varint(d.baseLength);
      w.varint(d.newLength);
      for (const b of d.blocks) {
        w.varint(b.x);
        w.varint(b.y);
        w.svarint(b.z);
        w.bytes(b.diff);
        w.bytes(b.extra);
      }
    }
  }
  w.byte(OP.END);
}

/** A whole patch: [files] of {path, target: Buffer, base: Buffer|null, ops}. */
function encodePatch(files) {
  const w = new Writer();
  w.varint(files.length);
  for (const f of files) {
    const p = Buffer.from(f.path, 'utf8');
    w.varint(p.length);
    w.bytes(p);
    w.varint(f.target.length);
    w.bytes(sha(f.target));
    if (f.base) {
      w.byte(1);
      w.bytes(sha(f.base));
    } else {
      w.byte(0);
    }
    writeOps(w, f.ops);
  }
  return Buffer.concat([MAGIC, Buffer.from([VERSION]), zlib.deflateRawSync(w.done(), { level: 9 })]);
}

/** Applies [patch] (the checker before publishing; the device has its own reader). [baseFor](path, sha) gives a base. */
function applyPatch(patch, baseFor) {
  if (patch.length < 9 || !patch.subarray(0, 8).equals(MAGIC) || patch[8] !== VERSION) throw new Error('not a CAWPATCH v1');
  const r = new Reader(zlib.inflateRawSync(patch.subarray(9)));
  const count = r.varint();
  const out = [];
  for (let i = 0; i < count; i++) {
    const p = r.take(r.varint()).toString('utf8');
    const size = r.varint();
    const want = r.take(32);
    const base = r.byte() === 1 ? baseFor(p, r.take(32)) : null;
    const buf = Buffer.alloc(size);
    let at = 0;
    for (;;) {
      const op = r.byte();
      if (op === OP.END) break;
      if (op === OP.COPY) {
        const off = r.varint();
        const len = r.varint();
        if (!base || off + len > base.length || at + len > size) throw new Error('copy out of range');
        base.copy(buf, at, off, off + len);
        at += len;
      } else if (op === OP.DATA) {
        const len = r.varint();
        if (at + len > size) throw new Error('data out of range');
        r.take(len).copy(buf, at);
        at += len;
      } else if (op === OP.BSDIFF) {
        const bo = r.varint();
        const bl = r.varint();
        const nl = r.varint();
        if (!base || bo + bl > base.length || at + nl > size) throw new Error('bsdiff out of range');
        let pos = 0;
        const end = at + nl;
        while (at < end) {
          const x = r.varint();
          const y = r.varint();
          const z = r.svarint();
          if (at + x + y > end) throw new Error('bsdiff block out of range');
          const diff = r.take(x);
          for (let j = 0; j < x; j++) {
            const o = pos + j;
            buf[at + j] = (diff[j] + (o >= 0 && o < bl ? base[bo + o] : 0)) & 0xff;
          }
          at += x;
          r.take(y).copy(buf, at);
          at += y;
          pos += x + z;
        }
      } else {
        throw new Error(`unknown op ${op}`);
      }
    }
    if (at !== size || !sha(buf).equals(want)) throw new Error(`${p}: the rebuilt file does not match`);
    out.push({ path: p, data: buf });
  }
  if (r.pos !== r.buf.length) throw new Error('trailing bytes in patch');
  return out;
}

// ---- Zip reading (APK and the Windows zip; no zip64: both are far below 4 GB) ----

/** The entries of zip [buf]: name, method, flags, sizes, crc, local header offset, data start and end. */
function readZip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65535); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a zip (no end record)');
  const count = buf.readUInt16LE(eocd + 10);
  const cdSize = buf.readUInt32LE(eocd + 12);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  if (count === 0xffff || cdOffset === 0xffffffff) throw new Error('zip64 is not supported');
  const entries = [];
  let p = cdOffset;
  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('bad central directory');
    const flags = buf.readUInt16LE(p + 8);
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const compSize = buf.readUInt32LE(p + 20);
    const size = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const lho = buf.readUInt32LE(p + 42);
    const name = buf.subarray(p + 46, p + 46 + nameLen).toString('utf8');
    p += 46 + nameLen + extraLen + commentLen;
    if (buf.readUInt32LE(lho) !== 0x04034b50) throw new Error(`bad local header for ${name}`);
    const dataStart = lho + 30 + buf.readUInt16LE(lho + 26) + buf.readUInt16LE(lho + 28);
    entries.push({ name, flags, method, crc, compSize, size, lho, dataStart, dataEnd: dataStart + compSize });
  }
  return { entries, cdOffset, cdSize, eocd };
}

function content(buf, e) {
  const raw = buf.subarray(e.dataStart, e.dataEnd);
  if (e.method === 0) return raw;
  if (e.method === 8) return zlib.inflateRawSync(raw);
  throw new Error(`${e.name}: compression method ${e.method} is not supported`);
}

/** Every file of zip [buf] (directories left out) with its size and SHA-256 of its contents. */
function listFiles(buf) {
  return readZip(buf)
    .entries.filter((e) => !e.name.endsWith('/'))
    .map((e) => {
      const c = content(buf, e);
      return { path: e.name, size: c.length, sha256: hex(sha(c)) };
    });
}

// ---- bsdiff (Colin Percival's bsdiff 4, BSD-2-Clause, from the runner's package manager; docs/decisions.md) ----

function haveTool(name) {
  const r = spawnSync('sh', ['-c', `command -v ${name}`], { encoding: 'utf8' });
  return r.status === 0;
}

/** 8-byte sign-magnitude little-endian integer (bsdiff's offtin). */
function offtin(b, at) {
  let y = b[at + 7] & 0x7f;
  for (let i = 6; i >= 0; i--) y = y * 256 + b[at + i];
  return b[at + 7] & 0x80 ? -y : y;
}

function bunzip(buf) {
  const r = spawnSync('bzip2', ['-dc'], { input: buf, maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Error('bzip2 failed');
  return r.stdout;
}

/** bsdiff's blocks from [base] to [target], or null without the tools. Read from BSDIFF40 (its blocks are bzip2). */
function bsdiffBlocks(base, target, tmp) {
  const a = path.join(tmp, 'a');
  const b = path.join(tmp, 'b');
  const p = path.join(tmp, 'p');
  fs.writeFileSync(a, base);
  fs.writeFileSync(b, target);
  const r = spawnSync('bsdiff', [a, b, p], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`bsdiff failed: ${r.stderr}`);
  const patch = fs.readFileSync(p);
  if (patch.subarray(0, 8).toString('ascii') !== 'BSDIFF40') throw new Error('bsdiff wrote another format');
  const ctrlLen = offtin(patch, 8);
  const diffLen = offtin(patch, 16);
  const newSize = offtin(patch, 24);
  if (newSize !== target.length) throw new Error('bsdiff size mismatch');
  const ctrl = bunzip(patch.subarray(32, 32 + ctrlLen));
  const diff = bunzip(patch.subarray(32 + ctrlLen, 32 + ctrlLen + diffLen));
  const extra = bunzip(patch.subarray(32 + ctrlLen + diffLen));
  const blocks = [];
  let di = 0;
  let ei = 0;
  for (let i = 0; i + 24 <= ctrl.length; i += 24) {
    const x = offtin(ctrl, i);
    const y = offtin(ctrl, i + 8);
    const z = offtin(ctrl, i + 16);
    if (x < 0 || y < 0) throw new Error('bad bsdiff control');
    blocks.push({ x, y, z, diff: diff.subarray(di, di + x), extra: extra.subarray(ei, ei + y) });
    di += x;
    ei += y;
  }
  if (di !== diff.length || ei !== extra.length) throw new Error('bsdiff blocks do not add up');
  return blocks;
}

/** The cheaper of whole data and a bsdiff for one changed file or entry (judged by its deflated size). */
function cheapest(base, baseOffset, baseLength, target, opts) {
  const whole = [{ data: target }];
  const useBsdiff = opts.bsdiff && baseLength > 0 && target.length >= opts.bsdiffMin && target.length <= 64 << 20;
  if (!useBsdiff) return whole;
  try {
    const blocks = bsdiffBlocks(base.subarray(baseOffset, baseOffset + baseLength), target, opts.tmp);
    const viaDiff = [{ bsdiff: { baseOffset, baseLength, newLength: target.length, blocks } }];
    const size = (ops) => {
      const w = new Writer();
      writeOps(w, ops);
      return zlib.deflateRawSync(w.done(), { level: 6 }).length;
    };
    return size(viaDiff) < size(whole) ? viaDiff : whole;
  } catch (e) {
    opts.log(`WARN bsdiff - ${e.message}; whole data used`);
    return whole;
  }
}

/** Joins neighbouring copies and data. */
function coalesce(ops) {
  const out = [];
  for (const op of ops) {
    const last = out[out.length - 1];
    if (op.copy && last && last.copy && last.copy[0] + last.copy[1] === op.copy[0]) {
      last.copy = [last.copy[0], last.copy[1] + op.copy[1]];
    } else if (op.data && last && last.data) {
      last.data = Buffer.concat([last.data, op.data]);
    } else if (!(op.data && op.data.length === 0)) {
      out.push(op.copy ? { copy: [...op.copy] } : op);
    }
  }
  return out;
}

/**
 * The ops that rebuild [next] (an APK) byte for byte from [prev]: every entry whose stored bytes are unchanged is
 * copied from the old APK (its local header too when that is the same), changed entries are new data (or a bsdiff
 * for an uncompressed one), and everything between and after (the signing block, the central directory) is data.
 */
function apkOps(prev, next, opts) {
  const old = readZip(prev).entries;
  const byKey = new Map();
  const byName = new Map();
  for (const e of old) {
    const k = `${e.crc}:${e.compSize}:${e.size}:${e.method}`;
    if (!byKey.has(k)) byKey.set(k, []);
    byKey.get(k).push(e);
    byName.set(e.name, e);
  }
  const entries = readZip(next).entries.slice().sort((a, b) => a.lho - b.lho);
  const ops = [];
  let at = 0;
  for (const e of entries) {
    if (e.lho < at) throw new Error('overlapping zip entries');
    ops.push({ data: next.subarray(at, e.lho) });
    const header = next.subarray(e.lho, e.dataStart);
    const data = next.subarray(e.dataStart, e.dataEnd);
    const same = (byKey.get(`${e.crc}:${e.compSize}:${e.size}:${e.method}`) || []).find((o) =>
      prev.subarray(o.dataStart, o.dataEnd).equals(data));
    if (same) {
      const oldHeader = prev.subarray(same.lho, same.dataStart);
      ops.push(oldHeader.equals(header) ? { copy: [same.lho, header.length] } : { data: header });
      ops.push({ copy: [same.dataStart, data.length] });
    } else {
      ops.push({ data: header });
      const o = byName.get(e.name);
      if (o && o.method === 0 && e.method === 0) ops.push(...cheapest(prev, o.dataStart, o.compSize, data, opts));
      else ops.push({ data });
    }
    at = e.dataEnd;
  }
  ops.push({ data: next.subarray(at) });
  return coalesce(ops);
}

/** The per-file patch entries that turn the files of zip [prev] into those of [next] (changed and new files). */
function filesPatchEntries(prev, next, opts) {
  const oldFiles = new Map();
  for (const e of readZip(prev).entries) if (!e.name.endsWith('/')) oldFiles.set(e.name, content(prev, e));
  const out = [];
  for (const e of readZip(next).entries) {
    if (e.name.endsWith('/')) continue;
    const target = content(next, e);
    const base = oldFiles.get(e.name);
    if (base && base.equals(target)) continue;
    const ops = base ? cheapest(base, 0, base.length, target, opts) : [{ data: target }];
    out.push({ path: e.name, target, base: ops[0].bsdiff ? base : null, ops });
  }
  return out;
}

// ---- Choosing the previous release of a channel (tagged releases) ----

function parseVersion(s) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(String(s || '').trim());
  return m ? { nums: [+m[1], +m[2], +m[3]], pre: m[4] ? m[4].split('.') : [] } : null;
}

function compareVersions(a, b) {
  for (let i = 0; i < 3; i++) if (a.nums[i] !== b.nums[i]) return a.nums[i] - b.nums[i];
  if (!a.pre.length || !b.pre.length) return (a.pre.length ? 0 : 1) - (b.pre.length ? 0 : 1);
  for (let i = 0; i < Math.min(a.pre.length, b.pre.length); i++) {
    const x = a.pre[i];
    const y = b.pre[i];
    const nx = /^\d+$/.test(x);
    const ny = /^\d+$/.test(y);
    if (nx && ny && +x !== +y) return +x - +y;
    if (nx !== ny) return nx ? -1 : 1;
    if (!nx && x !== y) return x < y ? -1 : 1;
  }
  return a.pre.length - b.pre.length;
}

/** Stable (alpha and full releases) builds on Stable's previous release; any other stage on the newest earlier one. */
function pickBase(releases, version) {
  const v = parseVersion(version);
  if (!v) return null;
  const stable = (x) => !x.pre.length || x.pre[0].toLowerCase() === 'alpha';
  let best = null;
  for (const r of releases) {
    if (!r || r.draft || typeof r.tag_name !== 'string' || !r.tag_name.startsWith('v')) continue;
    const rv = parseVersion(r.tag_name);
    if (!rv || compareVersions(rv, v) >= 0) continue;
    if (stable(v) && !stable(rv)) continue;
    if (!best || compareVersions(rv, best.v) > 0) best = { tag: r.tag_name, v: rv };
  }
  return best ? best.tag : null;
}

// ---- The command ----

/**
 * Writes `<prefix>-update.json` and, when they come out smaller than the full download, `<prefix>-android.cawpatch`
 * and `<prefix>-windows.cawpatch`. Each patch is applied here and must rebuild its target exactly, or it is dropped.
 */
function build(o) {
  const log = o.log || ((l) => console.log(l));
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'caw-delta-'));
  const opts = { bsdiff: o.bsdiff !== false && haveTool('bsdiff') && haveTool('bzip2'), bsdiffMin: o.bsdiffMin ?? 64 * 1024, tmp, log };
  if (!opts.bsdiff) log('WARN bsdiff - bsdiff or bzip2 not found: changed files go whole');
  const manifest = { caw_update_manifest: 1, version: o.version, build: o.build || '', artifacts: [], patches: [] };
  const written = [];
  const kinds = [
    { kind: 'apk', file: o.apk, base: o.baseApk, name: `${o.prefix}-android.cawpatch` },
    { kind: 'files', file: o.zip, base: o.baseZip, name: `${o.prefix}-windows.cawpatch` },
  ];
  try {
    for (const k of kinds) {
      if (!k.file) continue;
      const next = fs.readFileSync(k.file);
      const asset = path.basename(k.file);
      manifest.artifacts.push({ asset, kind: k.kind, size: next.length, sha256: hex(sha(next)), files: listFiles(next) });
      if (!k.base || !fs.existsSync(k.base)) {
        log(`WARN ${k.kind} patch - no previous build: none made`);
        continue;
      }
      const prev = fs.readFileSync(k.base);
      try {
        let patch;
        if (k.kind === 'apk') {
          patch = encodePatch([{ path: asset, target: next, base: prev, ops: apkOps(prev, next, opts) }]);
          const [got] = applyPatch(patch, (p, s) => (sha(prev).equals(s) ? prev : null));
          if (!got.data.equals(next)) throw new Error('the rebuilt APK differs');
        } else {
          const entries = filesPatchEntries(prev, next, opts);
          patch = encodePatch(entries);
          const oldFiles = new Map(readZip(prev).entries.map((e) => [e.name, e]));
          const rebuilt = applyPatch(patch, (p, s) => {
            const e = oldFiles.get(p);
            const c = e && content(prev, e);
            return c && sha(c).equals(s) ? c : null;
          });
          const want = new Map(manifest.artifacts[manifest.artifacts.length - 1].files.map((f) => [f.path, f.sha256]));
          for (const f of rebuilt) if (want.get(f.path) !== hex(sha(f.data))) throw new Error(`${f.path} differs`);
        }
        if (patch.length >= next.length) {
          log(`WARN ${k.kind} patch - ${patch.length} bytes is not smaller than ${next.length}: none published`);
          continue;
        }
        fs.writeFileSync(path.join(o.out, k.name), patch);
        written.push(k.name);
        manifest.patches.push({
          asset: k.name,
          kind: k.kind,
          target: asset,
          base_build: o.baseBuild || '',
          base_sha256: hex(sha(prev)),
          size: patch.length,
          sha256: hex(sha(patch)),
        });
        log(`PASS ${k.kind} patch - ${k.name}: ${(patch.length / 1048576).toFixed(2)} MB instead of ${(next.length / 1048576).toFixed(2)} MB, rebuilt and checked`);
      } catch (e) {
        log(`WARN ${k.kind} patch - ${e.message}: none published`);
      }
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  const name = `${o.prefix}-update.json`;
  fs.writeFileSync(path.join(o.out, name), JSON.stringify(manifest));
  written.unshift(name);
  log(`PASS manifest - ${name}: ${manifest.artifacts.length} artefacts, ${manifest.patches.length} patches`);
  return { manifest, written };
}

function args(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    o[key] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  }
  return o;
}

function main(argv) {
  if (argv[0] === 'pick-base') {
    // Reads GitHub's release list on stdin; prints the tag the patches start from (nothing when there is none).
    const o = args(argv.slice(1));
    const tag = pickBase(JSON.parse(fs.readFileSync(0, 'utf8')), o.version);
    if (tag) process.stdout.write(`${tag}\n`);
    return 0;
  }
  const o = args(argv);
  if (!o.version || !o.prefix || (!o.apk && !o.zip)) {
    console.log('FAIL usage - update-delta.js --version V --prefix caw-main [--build B] --apk A --zip Z [--base-apk A0 --base-zip Z0 --base-build B0] [--out DIR] (scripts/update-delta.js)');
    return 1;
  }
  try {
    const { written } = build({ ...o, out: o.out || '.', bsdiffMin: o.bsdiffMin ? Number(o.bsdiffMin) : undefined, bsdiff: o.noBsdiff ? false : undefined });
    if (o.list) fs.writeFileSync(o.list, `${written.join('\n')}\n`);
    return 0;
  } catch (e) {
    console.log(`FAIL update assets - ${e.message} (scripts/update-delta.js)`);
    return 1;
  }
}

module.exports = { encodePatch, applyPatch, readZip, listFiles, apkOps, filesPatchEntries, pickBase, build, Writer };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
