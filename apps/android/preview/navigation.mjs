import { fileAddressFor, parseFileAddress, sessionFileAddress } from '../../../packages/util/workspace-path/src/index.ts';

/** Native navigation consumes the original file address and registered document type. */
export function createDocumentNavigation({ sessionId, path, tabs, open, reveal, report }) {
  const current = sessionFileAddress(sessionId, path);
  return {
    openFile(path, options) {
      return this.openResource(fileAddressFor(sessionId, undefined, path), options?.line === undefined ? undefined : { params: { line: options.line } });
    },
    async openResource(address, options) {
      try {
        const file = parseFileAddress(address);
        if (file?.scope !== 'session') throw Object.assign(new Error('This resource is not a Session document'), { code: 'document/unsupported-resource' });
        if (file.sessionId !== sessionId) throw Object.assign(new Error('The document belongs to another Session'), { code: 'document/session-mismatch' });
        const claim = tabs.claim(address);
        if (claim.kind !== 'text') throw Object.assign(new Error('This resource needs another viewer'), { code: 'document/unsupported-resource' });
        const line = options?.params?.line;
        if (line !== undefined && (!Number.isSafeInteger(line) || line < 1)) throw Object.assign(new Error('Invalid document line'), { code: 'document/invalid-target' });
        // Keep the native route's spelling when the original address identity
        // matches (for example ./guide.md versus guide.md).
        await open({ sessionId, path: address === current ? path : file.path, ...(line === undefined ? {} : { line }), replace: options?.replaceTab === true });
        if (address === current) reveal(line);
      } catch (error) {
        if (error.name !== 'AbortError') report(error);
      }
    },
    openTab() { report(Object.assign(new Error('This surface only opens Session documents'), { code: 'document/unsupported-resource' })); },
  };
}
