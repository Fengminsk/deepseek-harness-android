const VERSION = /^[0-9a-f]{64}$/
const PAGE_BYTES = 262144

/** Validate a SAF continuation before and after native IO without treating its URI as a filesystem path. */
export async function readAuthorizedDocument(nativeRead, params, requireContinuation = false) {
  const offset = params.offset ?? 0
  if (!Number.isSafeInteger(offset) || offset < 0) throw new TypeError('文件读取位置必须是非负安全整数')
  const expected = params.version
  if (expected !== undefined && (typeof expected !== 'string' || !VERSION.test(expected))) {
    throw new TypeError('文件版本标识无效，请从头读取')
  }
  if (requireContinuation && offset > 0 && expected === undefined) {
    throw new TypeError('继续读取需提供上一段返回的 version；请从头读取')
  }
  const result = await nativeRead({ root: params.root, path: params.path ?? '', offset,
    ...(expected === undefined ? {} : { version: expected }) })
  if (!result || typeof result !== 'object' || typeof result.version !== 'string' || !VERSION.test(result.version)) {
    throw new TypeError('文件提供方未返回可核对的版本，请重新打开文件')
  }
  if (expected !== undefined && result.version !== expected) {
    throw new Error('文件已移动或变化，不能把不同版本的内容接在一起；请从头读取')
  }
  // A matching revision alone does not prove that the returned page belongs
  // at the requested position. A shifted or non-progressing page would make
  // the model silently omit/duplicate text, or loop forever on continuation.
  if (typeof result.text !== 'string' || result.offset !== offset
    || !Number.isSafeInteger(result.nextOffset) || result.nextOffset < offset
    || result.nextOffset - offset > PAGE_BYTES || result.text.length > PAGE_BYTES
    || typeof result.truncated !== 'boolean'
    || (result.nextOffset === offset && (result.truncated || result.text.length > 0))
    || (result.nextOffset > offset && result.text.length === 0)) {
    throw new TypeError('文件提供方返回了不一致的分页位置，请从头重新读取')
  }
  // The native reader advances by bytes it decoded, not by UTF-16 units. A
  // shifted response with plausible offsets must not silently skip or repeat
  // model-visible content; reject lone surrogates that cannot round-trip.
  const encoded = Buffer.from(result.text, 'utf8')
  if (encoded.length !== result.nextOffset - offset
    || encoded.toString('utf8') !== result.text) {
    throw new TypeError('文件提供方返回了不一致的分页位置，请从头重新读取')
  }
  return result
}
