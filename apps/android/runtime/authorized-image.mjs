import { createHash, randomUUID } from 'node:crypto'
import { extname } from 'node:path'

const IMAGE_TYPES = new Map([
  ['.png', 'image/png'], ['.jpg', 'image/jpeg'], ['.jpeg', 'image/jpeg'],
  ['.webp', 'image/webp'], ['.gif', 'image/gif'],
])
const VERSION = /^[0-9a-f]{64}$/
const NATIVE_MAX_BYTES = 20 * 1024 * 1024

function sniff(bytes) {
  if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png'
  if (bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) return 'image/jpeg'
  if (bytes.subarray(0, 6).toString('ascii') === 'GIF87a'
    || bytes.subarray(0, 6).toString('ascii') === 'GIF89a') return 'image/gif'
  if (bytes.subarray(0, 4).toString('ascii') === 'RIFF'
    && bytes.subarray(8, 12).toString('ascii') === 'WEBP') return 'image/webp'
  return undefined
}

async function requireImageRoute(ctx, execution) {
  const routed = execution.agent?.session.requestHeader()?.config
  const provider = routed?.provider ?? execution.agent?.options.provider
  const model = routed?.model ?? execution.agent?.options.model
  const llm = ctx.get('llm')
  if (!provider || !model || !llm) throw new Error('当前模型路线无法确认是否支持图片，请先选择支持图片的模型')
  const info = await llm.resolveModelInfo(provider, model, execution.signal)
  if (!info.inputModalities?.includes('image')) {
    throw new Error(`模型 ${model} 未声明图片输入能力，请切换支持图片的模型`)
  }
}

function imageLimit(attachments) {
  const limits = attachments.imageLimits
  if (!limits || !Number.isSafeInteger(limits.maxImageBytes) || limits.maxImageBytes <= 0
    || !Number.isSafeInteger(limits.maxMessageImageBytes) || limits.maxMessageImageBytes <= 0
    || !Array.isArray(limits.mediaTypes)) throw new Error('图片存储策略暂不可用')
  return Math.min(NATIVE_MAX_BYTES, limits.maxImageBytes, limits.maxMessageImageBytes)
}

function decodeNativeImage(result, maxBytes) {
  if (!result || typeof result !== 'object' || typeof result.data !== 'string'
    || !Number.isSafeInteger(result.bytes) || result.bytes < 0 || result.bytes > maxBytes
    || typeof result.sha256 !== 'string' || !VERSION.test(result.sha256)
    || typeof result.version !== 'string' || !VERSION.test(result.version)
    || typeof result.name !== 'string' || result.name.length > 1024
    || result.data.length > Math.ceil(maxBytes / 3) * 4) {
    throw new TypeError('文件提供方返回的图片数据无效或超出限制')
  }
  const data = Buffer.from(result.data, 'base64')
  if (data.length !== result.bytes || data.toString('base64') !== result.data
    || createHash('sha256').update(data).digest('hex') !== result.sha256) {
    throw new TypeError('文件提供方返回的图片字节与校验值不一致')
  }
  return data
}

/** Read one persisted SAF grant as a durable model image with a revocable native request. */
export async function readAuthorizedImage(ctx, transport, args, execution) {
  if (!execution.agent) throw new Error('图片读取需要 Agent 会话')
  if (typeof args.root !== 'string' || args.root.length === 0
    || typeof args.path !== 'string') throw new TypeError('图片读取需要授权根和相对路径')
  const extension = extname(args.path).toLowerCase()
  if (extension && !IMAGE_TYPES.has(extension)) {
    throw new Error('文件扩展名不是 PNG、JPEG、WebP 或 GIF；请选取支持的图片')
  }
  const attachments = ctx.get('attachments')
  if (!attachments) throw new Error('图片附件服务暂不可用')
  const maxBytes = imageLimit(attachments)
  const declared = IMAGE_TYPES.get(extension)
  if (declared && !attachments.imageLimits.mediaTypes.includes(declared)) {
    throw new Error(`当前模型配置不接受 ${declared} 图片`)
  }
  await requireImageRoute(ctx, execution)
  execution.signal.throwIfAborted()
  const id = randomUUID()
  let requested = false
  const cancel = () => {
    if (requested) void transport.request('native.documents.image.cancel', { id }).catch(() => {})
  }
  execution.signal.addEventListener('abort', cancel, { once: true })
  try {
    requested = true
    const result = await transport.request('native.documents.image.read',
      { id, root: args.root, path: args.path, maxBytes }, execution.signal)
    execution.signal.throwIfAborted()
    const data = decodeNativeImage(result, maxBytes)
    const mediaType = sniff(data)
    if (!mediaType || (declared && declared !== mediaType)) {
      throw new Error('文件内容与图片格式不符；请重新选择有效的 PNG、JPEG、WebP 或 GIF 图片')
    }
    if (!attachments.imageLimits.mediaTypes.includes(mediaType)) {
      throw new Error(`当前模型配置不接受 ${mediaType} 图片`)
    }
    execution.signal.throwIfAborted()
    const ref = await attachments.saveImage({ data, mediaType, name: result.name })
    execution.signal.throwIfAborted()
    return { root: args.root, path: args.path, version: result.version,
      image: { attachmentId: ref.attachmentId, mediaType: ref.mediaType, bytes: ref.bytes,
        width: ref.width, height: ref.height,
        ...(ref.name === undefined ? {} : { name: ref.name }),
        ...(ref.originalDimensions === undefined ? {} : { originalDimensions: ref.originalDimensions }) } }
  } finally {
    execution.signal.removeEventListener('abort', cancel)
  }
}

/** Project a stored SAF image reference into the model's image content block. */
export function renderAuthorizedImage(args, result) {
  if (args.action !== 'read_image') return [{ type: 'text', text: JSON.stringify(result) }]
  const location = JSON.stringify({ root: result.root, path: result.path })
  return [
    { type: 'text', text: `已授权 Android 图片 ${location}，${result.image.mediaType}，${result.image.width}×${result.image.height}，${result.image.bytes} 字节。` },
    { type: 'image', attachment: result.image },
  ]
}
