import { DocumentRequests } from './document-requests.mjs'
import { readAuthorizedDocument } from './document-read.mjs'

/** Text pages share a cancellable native owner with the tool and the App reader. */
export class AppDocumentReads extends DocumentRequests {
  constructor(transport, { maxRequests, timeoutMs }) {
    super(transport, { method: 'native.documents.read', maxRequests,
      validate(params) {
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(params.requestId ?? '')) {
          throw new TypeError('Invalid document read request id')
        }
        if (!/^[0-9a-f]{64}$/.test(params.root ?? '')) throw new TypeError('Invalid document grant')
        if (typeof params.path !== 'string' || params.path.length > 4096) throw new TypeError('Invalid document path')
      },
      prepareParams: params => ({ root: params.root, timeoutMs: timeoutMs() }),
      execute: (params, run) => readAuthorizedDocument(run, params, true),
    })
  }
}
