import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const binary = readFileSync(process.argv[2]);
const { instance } = await WebAssembly.instantiate(binary);
const { memory, dsh_parse_direct_children: parse } = instance.exports;
assert.ok(memory && parse, 'child parser WASM exports');
const bytes = new Uint8Array(memory.buffer);
const result = new DataView(memory.buffer);
const inputAt = 1024;
const outputAt = 8192;

function parsed(input, capacity = 16) {
  bytes.fill(0, inputAt, inputAt + 128);
  bytes.set(Buffer.from(input), inputAt);
  const count = parse(inputAt, Buffer.byteLength(input), outputAt, capacity);
  return count < 0 ? count : Array.from({ length: count }, (_, i) =>
    result.getInt32(outputAt + i * 4, true));
}

assert.deepEqual(parsed(''), []);
assert.deepEqual(parsed(' \n'), []);
assert.deepEqual(parsed('42 '), [42]);
assert.deepEqual(parsed('42 123\n2147483647 '), [42, 123, 2147483647]);
for (const invalid of ['0 ', '-1 ', '+1 ', '1x ', '1\t2', '2147483648 ', '999999999999999999999 ']) {
  assert.equal(parsed(invalid), -1, `malformed snapshot: ${invalid}`);
}
assert.equal(parsed('1 2 ', 1), -1, 'snapshot cannot silently drop a child');
assert.deepEqual(parsed('1 2 ', 2), [1, 2]);
console.log('Linux guest direct-child snapshot parser PASS');
