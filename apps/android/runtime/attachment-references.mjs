/** Only declared first-party content carriers authorize a file; opaque payloads never do. */
export function attachmentContentsOf(event) {
  const data = event?.data
  if (!data || typeof data !== 'object') return []
  switch (event.type) {
    case 'user/message': case 'tool/ptc-dispatch': return [data.content]
    case 'system/message': case 'developer/message': case 'tool/result': case 'team/message/queued':
      return [data.message?.content]
    case 'agent/inbox/spliced': return Array.isArray(data.inserted) ? data.inserted.map(message => message?.content) : []
    case 'compaction/summary': return [data.summary, data.rawOutput]
    case 'assistant/message': case 'assistant/attempt': return [
      ...(event.type === 'assistant/message' ? [data.message?.content] : []),
      ...(Array.isArray(data.stream) ? data.stream.filter(record => record.type === 'chunk'
        && record.chunk?.type === 'block-end').map(record => [record.chunk.block]) : []),
    ]
    default: return []
  }
}

/** A reference is a digest plus a leaf name and size, never a caller-supplied host path. */
export function validFileReference(ref) {
  return ref && /^sha256:[a-f0-9]{64}$/.test(ref.attachmentId)
    && typeof ref.name === 'string' && ref.name.isWellFormed() && ref.name.length > 0
    && ref.name !== '.' && ref.name !== '..' && Buffer.byteLength(ref.name) <= 255
    && !/[\0-\x1f\x7f/\\:]/u.test(ref.name)
    && Number.isSafeInteger(ref.bytes) && ref.bytes >= 0
}

export function eventFileReferences(event) {
  const refs = []
  for (const content of attachmentContentsOf(event)) {
    if (!Array.isArray(content)) continue
    for (const part of content) {
      if (part?.type === 'file' && validFileReference(part.attachment)) {
        const { attachmentId, name, bytes } = part.attachment
        refs.push({ attachmentId, name, bytes })
      }
    }
  }
  return refs
}
