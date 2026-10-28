import { DocumentRequests } from './document-requests.mjs'

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const rootId = /^[0-9a-f]{64}$/

function validate(params) {
  if (typeof params.requestId !== 'string' || !uuid.test(params.requestId)) throw new TypeError('Invalid search request id')
  if (typeof params.root !== 'string' || !rootId.test(params.root)) throw new TypeError('Invalid document grant')
  if (typeof params.path !== 'string' || params.path.length > 4096 || (params.path !== '' && params.path.split('/').some(
    part => part === '' || part === '.' || part === '..' || part.includes('\\')))) throw new TypeError('Invalid relative document path')
  if (typeof params.query !== 'string' || params.query.length < 1 || params.query.length > 256
    || /[\r\n\0]/u.test(params.query) || !params.query.isWellFormed()) throw new TypeError('Search needs 1–256 characters on one line')
  if (typeof params.caseSensitive !== 'boolean') throw new TypeError('caseSensitive is required')
}

/** Bounded SAF search using the shared native request lifecycle. */
export class AppDocumentSearch extends DocumentRequests {
  constructor(transport, { limits, maxRequests }) {
    super(transport, { method: 'native.documents.search', validate, maxRequests,
      execute: (params, run) => run({ root: params.root, path: params.path, query: params.query,
        caseSensitive: params.caseSensitive, limits: limits() }),
    })
  }
}
