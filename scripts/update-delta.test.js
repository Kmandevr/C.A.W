// Tests the small-update builder: APK and Windows patches rebuild their targets byte for byte, the manifest lists every file, and the previous release of a channel is chosen right.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const { applyPatch, encodePatch, apkOps, build, pickBase, readZip } = require('./update-delta');

function crc32(buf) {
  let c = ~0;
  for (const b of buf) {
    c ^= b;
    for (let k = 0; k < 8; k++) c = c & 1 ? (c >>> 1) ^ 0xedb88320 : c >>> 1;
  }
  return ~c >>> 0;
}

/** A plain zip of [files] ({name, data, stored}), with [tail] bytes before the central directory (like a signing block). */
function makeZip(files, tail = Buffer.alloc(0)) {
  const locals = [];
  const central = [];
  let off = 0;
  for (const f of files) {
    const name = Buffer.from(f.name);
    const data = f.stored ? f.data : zlib.deflateRawSync(f.data, { level: 6 });
    const h = Buffer.alloc(30);
    h.writeUInt32LE(0x04034b50, 0);
    h.writeUInt16LE(20, 4);
    h.writeUInt16LE(f.stored ? 0 : 8, 8);
    h.writeUInt32LE(crc32(f.data), 14);
    h.writeUInt32LE(data.length, 18);
    h.writeUInt32LE(f.data.length, 22);
    h.writeUInt16LE(name.length, 26);
    locals.push(h, name, data);
    const c = Buffer.alloc(46);
    c.writeUInt32LE(0x02014b50, 0);
    c.writeUInt16LE(20, 4);
    c.writeUInt16LE(20, 6);
    c.writeUInt16LE(f.stored ? 0 : 8, 10);
    c.writeUInt32LE(crc32(f.data), 16);
    c.writeUInt32LE(data.length, 20);
    c.writeUInt32LE(f.data.length, 24);
    c.writeUInt16LE(name.length, 28);
    c.writeUInt32LE(off, 42);
    central.push(c, name);
    off += 30 + name.length + data.length;
  }
  const body = Buffer.concat([...locals, tail]);
  const cd = Buffer.concat(central);
  const e = Buffer.alloc(22);
  e.writeUInt32LE(0x06054b50, 0);
  e.writeUInt16LE(files.length, 8);
  e.writeUInt16LE(files.length, 10);
  e.writeUInt32LE(cd.length, 12);
  e.writeUInt32LE(body.length, 16);
  return Buffer.concat([body, cd, e]);
}

/** Deterministic bytes. */
function bytes(n, seed) {
  const out = Buffer.alloc(n);
  let x = seed >>> 0 || 1;
  for (let i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    out[i] = x & 0xff;
  }
  return out;
}

/** An old and a new build: one file unchanged, one changed in a few bytes (stored, so bsdiff can help), one new. */
function builds() {
  const big = bytes(96 * 1024, 7);
  const bigNew = Buffer.from(big);
  bigNew.write('changed!', 5000);
  bigNew.write('again', 70000);
  const old = makeZip(
    [
      { name: 'lib/libapp.so', data: big, stored: true },
      { name: 'assets/same.txt', data: Buffer.from('unchanged '.repeat(200)) },
      { name: 'res/gone.txt', data: Buffer.from('removed') },
    ],
    Buffer.from('OLD-SIGNING-BLOCK'),
  );
  const next = makeZip(
    [
      { name: 'assets/same.txt', data: Buffer.from('unchanged '.repeat(200)) },
      { name: 'lib/libapp.so', data: bigNew, stored: true },
      { name: 'res/new.txt', data: Buffer.from('a new file '.repeat(50)) },
    ],
    Buffer.from('NEW-SIGNING-BLOCK-1234'),
  );
  return { old, next };
}

const sha = (b) => crypto.createHash('sha256').update(b).digest();

test('an APK patch rebuilds the new APK byte for byte from the old one', () => {
  const { old, next } = builds();
  const ops = apkOps(old, next, { bsdiff: false, log: () => {} });
  assert.ok(ops.some((o) => o.copy), 'the unchanged entry is copied');
  const patch = encodePatch([{ path: 'caw.apk', target: next, base: old, ops }]);
  const [got] = applyPatch(patch, (p, s) => (sha(old).equals(s) ? old : null));
  assert.ok(got.data.equals(next));
  assert.throws(() => applyPatch(patch, () => null), /out of range/);
});

test('build writes a manifest of every file and patches that are checked before they are written', () => {
  const { old, next } = builds();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'caw-delta-test-'));
  try {
    for (const [n, b] of [['old.apk', old], ['caw-main-android.apk', next], ['old.zip', old], ['caw-main-windows.zip', next]]) fs.writeFileSync(path.join(dir, n), b);
    const lines = [];
    const { manifest, written } = build({
      version: '1.0.0-alpha.2', build: 'abc1234', prefix: 'caw-main', out: dir, bsdiffMin: 0, log: (l) => lines.push(l),
      apk: path.join(dir, 'caw-main-android.apk'), baseApk: path.join(dir, 'old.apk'), zip: path.join(dir, 'caw-main-windows.zip'), baseZip: path.join(dir, 'old.zip'), baseBuild: 'def5678',
    });
    assert.deepEqual(written, ['caw-main-update.json', 'caw-main-android.cawpatch', 'caw-main-windows.cawpatch']);
    assert.equal(manifest.artifacts[0].files.length, 3);
    assert.equal(manifest.artifacts[0].sha256, sha(next).toString('hex'));
    assert.equal(manifest.patches.length, 2);
    assert.equal(manifest.patches[0].base_sha256, sha(old).toString('hex'));
    // The Windows patch holds only the changed and new files.
    const files = applyPatch(fs.readFileSync(path.join(dir, 'caw-main-windows.cawpatch')), (p) => {
      const e = readZip(old).entries.find((x) => x.name === p);
      return e ? old.subarray(e.dataStart, e.dataEnd) : null;
    });
    assert.deepEqual(files.map((f) => f.path).sort(), ['lib/libapp.so', 'res/new.txt']);
    if (process.env.CAW_WRITE_FIXTURES) {
      // The Dart tests' fixtures (app/test/fixtures/updates/): the same builds and patches.
      const out = process.env.CAW_WRITE_FIXTURES;
      fs.mkdirSync(out, { recursive: true });
      fs.writeFileSync(path.join(out, 'base.zip'), old);
      fs.writeFileSync(path.join(out, 'target.zip'), next);
      for (const n of ['caw-main-android.cawpatch', 'caw-main-windows.cawpatch', 'caw-main-update.json']) fs.copyFileSync(path.join(dir, n), path.join(out, n));
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('no previous build: a manifest without patches', () => {
  const { next } = builds();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'caw-delta-test-'));
  try {
    fs.writeFileSync(path.join(dir, 'new.apk'), next);
    const { manifest, written } = build({ version: '1.0.0', prefix: 'caw-1.0.0', out: dir, apk: path.join(dir, 'new.apk'), baseApk: path.join(dir, 'missing.apk'), log: () => {} });
    assert.deepEqual(written, ['caw-1.0.0-update.json']);
    assert.equal(manifest.patches.length, 0);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the previous release of the same channel is the base', () => {
  const rels = [
    { tag_name: 'v1.0.0-alpha.1' },
    { tag_name: 'v1.0.0-beta.1' },
    { tag_name: 'v1.0.0-alpha.2' },
    { tag_name: 'v1.0.0-alpha.3', draft: true },
    { tag_name: 'latest-main' },
    { tag_name: 'v2.0.0' },
  ];
  assert.equal(pickBase(rels, '1.0.0-alpha.3'), 'v1.0.0-alpha.2');
  assert.equal(pickBase(rels, '1.0.0-beta.2'), 'v1.0.0-beta.1');
  assert.equal(pickBase(rels, '1.0.0'), 'v1.0.0-alpha.2');
  assert.equal(pickBase(rels, '0.1.0'), null);
});
