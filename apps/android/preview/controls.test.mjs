import test from 'node:test';
import assert from 'node:assert/strict';
import { createDocumentControls } from './controls.mjs';

test('native refresh delegates to the mounted original reader and retires stale bindings', () => {
  const controls = createDocumentControls();
  let first = 0;
  let second = 0;
  assert.equal(controls.refresh(), false);
  const releaseFirst = controls.bind({ refresh: () => first++ });
  assert.equal(controls.refresh(), true);
  const releaseSecond = controls.bind({ refresh: () => second++ });
  releaseFirst();
  assert.equal(controls.refresh(), true);
  assert.deepEqual([first, second], [1, 1]);
  releaseSecond();
  assert.equal(controls.refresh(), false);
  controls.close();
  controls.bind({ refresh: () => first++ });
  assert.equal(controls.refresh(), false);
});
