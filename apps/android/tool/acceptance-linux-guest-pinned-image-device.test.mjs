import test from 'node:test'
import assert from 'node:assert/strict'
import { parsePinnedImageResult } from './acceptance-linux-guest-pinned-image-device.mjs'

test('accepts only the explicit pinned stage and normal retirement receipt', () => {
  const output = [
    'INSTRUMENTATION_RESULT: result=pinned-image-stage-and-retire-pass',
    'INSTRUMENTATION_RESULT: sha256=4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50',
    'INSTRUMENTATION_CODE: -1',
  ].join('\n')
  assert.equal(parsePinnedImageResult(output).result, 'pinned-image-stage-and-retire-pass')
  for (const rejected of [
    output.replace('INSTRUMENTATION_CODE: -1', 'INSTRUMENTATION_CODE: 0'),
    output.replace('pinned-image-stage-and-retire-pass', 'pinned-image-stage-and-retire-fail'),
    output.replace('INSTRUMENTATION_CODE: -1', ''),
  ]) assert.throws(() => parsePinnedImageResult(rejected), /unverified/)
})
