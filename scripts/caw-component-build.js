// Builds a C.A.W. component project and writes compiler diagnostics as JSON.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function parseDiagnostics(output) {
  const diagnostics = [];
  const gcc = /^(.*?):(\d+):(\d+):\s*(fatal error|error|warning|note):\s*(.*)$/;
  const msvc = /^(.*)\((\d+),(\d+)\):\s*(fatal error|error|warning|note)\s*([A-Z]+\d+)?\s*:\s*(.*)$/;
  for (const line of output.split(/\r?\n/)) {
    let match = line.match(gcc);
    if (match) {
      diagnostics.push({
        file: match[1],
        line: Number(match[2]),
        column: Number(match[3]),
        severity: match[4] === 'fatal error' ? 'error' : match[4],
        code: null,
        message: match[5],
      });
      continue;
    }
    match = line.match(msvc);
    if (match) {
      diagnostics.push({
        file: match[1],
        line: Number(match[2]),
        column: Number(match[3]),
        severity: match[4] === 'fatal error' ? 'error' : match[4],
        code: match[5] || null,
        message: match[6],
      });
    }
  }
  return diagnostics;
}

function parseArgs(argv) {
  const values = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--') || i + 1 >= argv.length) {
      throw new Error(`Expected --option value, got: ${key}`);
    }
    values[key.slice(2)] = argv[++i];
  }
  for (const key of ['project', 'sdk', 'build']) {
    if (!values[key]) throw new Error(`Missing required --${key}`);
  }
  return {
    project: path.resolve(values.project),
    sdk: path.resolve(values.sdk),
    build: path.resolve(values.build),
    config: values.config || 'Release',
    toolchain: values.toolchain ? path.resolve(values.toolchain) : null,
    androidAbi: values['android-abi'] || null,
    androidPlatform: values['android-platform'] || null,
    diagnostics: path.resolve(values.diagnostics || path.join(values.build, 'caw-build-diagnostics.json')),
  };
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', windowsHide: true });
  const output = [result.stdout || '', result.stderr || ''].filter(Boolean).join('\n');
  if (output) process.stdout.write(output.endsWith('\n') ? output : `${output}\n`);
  if (result.error) throw result.error;
  return { status: result.status === null ? 1 : result.status, output };
}

function build(options) {
  fs.mkdirSync(options.build, { recursive: true });
  const configureArgs = [
    '-S', options.project,
    '-B', options.build,
    `-DCMAKE_PREFIX_PATH=${options.sdk}`,
    `-DCMAKE_BUILD_TYPE=${options.config}`,
  ];
  if (options.toolchain) configureArgs.push(`-DCMAKE_TOOLCHAIN_FILE=${options.toolchain}`);
  if (options.androidAbi) configureArgs.push(`-DANDROID_ABI=${options.androidAbi}`);
  if (options.androidPlatform) configureArgs.push(`-DANDROID_PLATFORM=${options.androidPlatform}`);
  const configure = run('cmake', configureArgs, options.project);
  let status = configure.status;
  let output = configure.output;
  if (status === 0) {
    const compile = run('cmake', [
      '--build', options.build,
      '--config', options.config,
      '--parallel',
    ], options.project);
    status = compile.status;
    output += compile.output;
  }
  const diagnostics = parseDiagnostics(output);
  if (status !== 0 && diagnostics.length === 0) {
    const lines = output.trim().split(/\r?\n/);
    diagnostics.push({
      file: null,
      line: null,
      column: null,
      severity: 'error',
      code: 'CAW_BUILD_FAILED',
      message: lines[lines.length - 1] || 'C.A.W. component build failed without a compiler diagnostic.',
    });
  }
  fs.mkdirSync(path.dirname(options.diagnostics), { recursive: true });
  fs.writeFileSync(options.diagnostics, JSON.stringify({
    schemaVersion: 1,
    success: status === 0,
    exitCode: status,
    diagnostics,
  }, null, 2) + '\n');
  return status;
}

if (require.main === module) {
  try {
    process.exitCode = build(parseArgs(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`caw-component-build: ${error.message}\n`);
    process.exitCode = 2;
  }
}

module.exports = { parseDiagnostics, parseArgs, build };
