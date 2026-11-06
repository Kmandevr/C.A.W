// Tests parsing of compiler diagnostics used by the C.A.W. component build workflow.
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseDiagnostics } = require('./caw-component-build');

test('parses GCC and Clang file, line, column and message diagnostics', () => {
  const parsed = parseDiagnostics(
    'src/filter.cpp:18:7: error: use of undeclared identifier\n' +
    'src/filter.cpp:22:3: warning: unused variable'
  );
  assert.deepEqual(parsed, [
    {
      file: 'src/filter.cpp',
      line: 18,
      column: 7,
      severity: 'error',
      code: null,
      message: 'use of undeclared identifier',
    },
    {
      file: 'src/filter.cpp',
      line: 22,
      column: 3,
      severity: 'warning',
      code: null,
      message: 'unused variable',
    },
  ]);
});

test('parses MSVC diagnostics including the compiler code', () => {
  const parsed = parseDiagnostics(
    'C:\\work\\component.cpp(31,9): error C2065: undeclared identifier'
  );
  assert.deepEqual(parsed, [{
    file: 'C:\\work\\component.cpp',
    line: 31,
    column: 9,
    severity: 'error',
    code: 'C2065',
    message: 'undeclared identifier',
  }]);
});

test('does not mistake CMake progress lines for compiler diagnostics', () => {
  assert.deepEqual(parseDiagnostics('[100%] Built target caw_component'), []);
});
