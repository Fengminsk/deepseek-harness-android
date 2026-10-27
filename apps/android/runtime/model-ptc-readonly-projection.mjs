/** Bounded, explicit guest views of completed read-only ToolRuntime results. */
export const READONLY_PTC_RESULT_BYTES = 48 * 1024
const bytes = value => Buffer.byteLength(JSON.stringify(value), 'utf8')
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value)

function fitText(text, build, even = false) {
  if (typeof text !== 'string') throw new TypeError('Read-only PTC expected text')
  let low = 0, high = text.length
  const prefix = length => {
    if (even) length -= length % 2
    if (length > 0 && /[\uD800-\uDBFF]/u.test(text[length - 1])) length--
    return text.slice(0, length)
  }
  if (bytes(build('')) > READONLY_PTC_RESULT_BYTES) throw new TypeError('Read-only PTC metadata exceeds the reply limit')
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    if (bytes(build(prefix(middle))) <= READONLY_PTC_RESULT_BYTES) low = middle
    else high = middle - 1
  }
  const selected = prefix(low)
  if (!selected && text) throw new TypeError('Read-only PTC cannot return a progressing text page')
  return build(selected)
}

function fitItems(items, build) {
  if (!Array.isArray(items)) throw new TypeError('Read-only PTC expected a collection')
  let low = 0, high = items.length
  if (bytes(build([])) > READONLY_PTC_RESULT_BYTES) throw new TypeError('Read-only PTC metadata exceeds the reply limit')
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    if (bytes(build(items.slice(0, middle))) <= READONLY_PTC_RESULT_BYTES) low = middle
    else high = middle - 1
  }
  if (!low && items.length) throw new TypeError('One read-only PTC entry exceeds the reply limit')
  return build(items.slice(0, low))
}

/**
 * Project only a successfully settled, first-party read-only value. Truncation
 * preserves byte offsets for file pages and line offsets for workspace reads.
 * Search/fetch truncation is explicit; it never invents a resumable provider.
 */
export function projectReadOnlyPtcResult(name, args, value) {
  const original = Array.isArray(value) ? { items: value, truncated: false } : value
  if (!object(original)) throw new TypeError('Read-only PTC expected a structured tool value')
  if (bytes(original) <= READONLY_PTC_RESULT_BYTES) return original
  if (name === 'read') {
    if (!Number.isSafeInteger(value.offset) || !Number.isSafeInteger(value.totalLines)) throw new TypeError('Invalid read page')
    return fitItems(value.lines, lines => ({ ...value, lines, truncated: true,
      nextOffset: lines.length ? lines.at(-1).number + 1 : value.offset }))
  }
  if (name === 'web_fetch') {
    if (!object(value.body)) throw new TypeError('Invalid web page')
    return fitText(value.body.content, content => ({ ...value, body: { ...value.body, content },
      truncated: true, recovery: 'This is a bounded page excerpt; use a narrower source or query for omitted content.' }))
  }
  if (name === 'android_files' && args.action === 'read') {
    if (!Number.isSafeInteger(value.offset) || typeof value.version !== 'string') throw new TypeError('Invalid SAF page')
    return fitText(value.text, text => ({ ...value, text, truncated: true,
      nextOffset: value.offset + Buffer.byteLength(text, 'utf8') }))
  }
  if (name === 'android_attachments' && args.action === 'read') {
    if (!Number.isSafeInteger(value.offset) || !['utf8', 'hex'].includes(value.encoding)) throw new TypeError('Invalid attachment page')
    return fitText(value.content, content => ({ ...value, content, truncated: true,
      nextOffset: value.offset + (value.encoding === 'hex' ? content.length / 2 : Buffer.byteLength(content, 'utf8')) }),
    value.encoding === 'hex')
  }
  const arrayKey = ['items', 'paths', 'matches', 'sources', 'roots', 'entries', 'files'].find(key => Array.isArray(original[key]))
  if (arrayKey === undefined) throw new TypeError('Read-only PTC has no bounded view for this result')
  let metadata = { ...original }
  if (name === 'web_search' && typeof metadata.content === 'string') {
    metadata = fitText(metadata.content, content => ({ ...original, sources: [], content,
      truncated: true }), false)
    // Reserve space for source URLs instead of letting the provider answer fill the reply.
    const end = /[\uD800-\uDBFF]/u.test(metadata.content[4095] ?? '') ? 4095 : 4096
    metadata.content = metadata.content.slice(0, end)
  }
  return fitItems(original[arrayKey], items => ({ ...metadata, [arrayKey]: items, truncated: true,
    ...(name === 'android_attachments' ? { nextOffset: (args.offset ?? 0) + items.length }
      : { recovery: 'Narrow the directory, search pattern or query to inspect omitted entries.' }) }))
}
