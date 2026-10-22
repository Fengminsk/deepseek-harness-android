import { createSecretRule } from './secret-mask/secret-rule.js'

/** A pure display query. Raw text is never persisted or retained by this carrier. */
export function maskUserText(params) {
  if (typeof params?.text !== 'string') throw new TypeError('User text must be a string')
  // Bound the Binder request and result. Never include submitted text in errors.
  if (Buffer.byteLength(params.text, 'utf8') > 512 * 1024) throw new RangeError('User text exceeds the display scan limit')
  const rule = createSecretRule()
  const ranges = []
  let offset = 0
  while (offset < params.text.length) {
    const match = rule.match(params.text, offset)
    if (!match) break
    if (match.start < offset || match.end <= match.start || match.end > params.text.length) {
      throw new Error('Original credential matcher returned invalid coordinates')
    }
    ranges.push({ start: match.start, end: match.end, masked: match.data.masked })
    offset = match.end
  }
  return { ranges }
}
