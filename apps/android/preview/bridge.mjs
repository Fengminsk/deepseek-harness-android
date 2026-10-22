/** Document-only transport. The native host owns the session and every file capability. */
export const BYTE_CHUNK = 256 * 1024;
const METHODS = { workspaceFiles: new Set(['stat', 'read', 'readBytes', 'list']), officeToPdf: new Set(['render', 'generation']) };

const aborted = () => new DOMException('Document preview closed', 'AbortError');
const remoteFailure = error => Object.assign(new Error(error?.message ?? 'Document request failed'), error ?? {});

export class DocumentBridge {
  #channel; #next = 0; #pending = new Map(); #streams = new Map(); #closed = false;
  constructor(channel) {
    if (!channel || typeof channel.postMessage !== 'function') throw new Error('Native document bridge unavailable');
    this.#channel = channel;
    channel.onmessage = event => this.#receive(event.data);
  }
  #send(frame) {
    if (this.#closed) throw aborted();
    this.#channel.postMessage(JSON.stringify({ id: `document-${++this.#next}`, ...frame }));
  }
  #receive(raw) {
    let frame;
    try { frame = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch { return; }
    if (!frame || typeof frame.id !== 'string') return;
    const stream = this.#streams.get(frame.id);
    if (stream) {
      if ('event' in frame) stream.queue.push(frame);
      else if (frame.done === true) stream.done = true;
      else if ('error' in frame || frame.result?.ok === false) {
        stream.error = remoteFailure(frame.error ?? frame.result.error); stream.done = true;
      }
      stream.wake?.();
      return;
    }
    const pending = this.#pending.get(frame.id);
    if (!pending) return;
    this.#pending.delete(frame.id); pending.clean();
    if ('error' in frame) pending.reject(remoteFailure(frame.error));
    else pending.resolve(frame.result);
  }
  request(kind, fields = {}, signal) {
    if (this.#closed || signal?.aborted) return Promise.reject(signal?.reason ?? aborted());
    const id = `document-${++this.#next}`;
    return new Promise((resolve, reject) => {
      const cancel = () => {
        if (!this.#pending.delete(id)) return;
        clean();
        this.#send({ kind: 'cancel', requestId: id });
        reject(signal.reason ?? aborted());
      };
      const clean = () => signal?.removeEventListener('abort', cancel);
      this.#pending.set(id, { resolve, reject, clean });
      signal?.addEventListener('abort', cancel, { once: true });
      try { this.#send({ id, kind, ...fields }); } catch (error) {
        this.#pending.delete(id); clean(); reject(error);
      }
    });
  }
  ready(signal) { return this.request('ready', {}, signal); }
  /** A file target, not a URL; native retains its bound Session and owns routing. */
  openDocument(target, signal) { return this.request('navigate', target, signal); }
  /** Delegate a user-selected Web link; the native host validates and launches it. */
  openExternalLink(url) {
    if (typeof url !== 'string') throw new Error('Invalid external document link');
    const target = new URL(url);
    if (!['http:', 'https:'].includes(target.protocol) || !target.hostname || target.username || target.password) {
      throw new Error('Invalid external document link');
    }
    this.#send({ kind: 'external', url: target.href });
  }
  async call(namespace, method, args, signal) {
    if (!METHODS[namespace]?.has(method)) throw new Error('Method is outside the document bridge');
    const result = await this.request('call', { namespace, method, args }, signal);
    if (result?.ok !== true || !result.value?.data) return result;
    const data = result.value.data;
    if (data.encoding !== 'android-byte-lease') throw new Error('Unsupported document byte transport');
    const bytes = await this.#readLease(data, signal);
    return { ...result, value: { ...result.value, data: bytes } };
  }
  async #readLease(lease, signal) {
    try {
      if (typeof lease.id !== 'string' || !Number.isSafeInteger(lease.length) || lease.length < 0) throw new Error('Invalid document byte lease');
      const output = new Uint8Array(lease.length);
      for (let offset = 0; offset < output.length;) {
        signal?.throwIfAborted();
        const length = Math.min(BYTE_CHUNK, output.length - offset);
        const response = await this.request('bytes', { leaseId: lease.id, offset, length }, signal);
        if (response?.ok !== true) throw remoteFailure(response?.error);
        const chunk = response.value;
        const binary = atob(chunk.data);
        if (chunk.offset !== offset || binary.length === 0 || binary.length > length || (chunk.eof && offset + binary.length !== output.length)) throw new Error('Invalid document byte chunk');
        for (let i = 0; i < binary.length; i++) output[offset + i] = binary.charCodeAt(i);
        offset += binary.length;
      }
      signal?.throwIfAborted();
      return output;
    } finally {
      if (!this.#closed && typeof lease.id === 'string') this.#send({ kind: 'release', leaseId: lease.id });
    }
  }
  async *changes(path, signal) {
    if (this.#closed || signal?.aborted) throw signal?.reason ?? aborted();
    const id = `document-${++this.#next}`;
    const stream = { queue: [], done: false, error: undefined, wake: undefined };
    this.#streams.set(id, stream);
    const cancel = () => { stream.done = true; stream.queue.length = 0; stream.wake?.(); };
    signal?.addEventListener('abort', cancel, { once: true });
    try {
      this.#send({ id, kind: 'subscribe', namespace: 'workspaceFiles', method: 'changes', args: { path } });
      while (!this.#closed && !signal?.aborted) {
        const frame = stream.queue.shift();
        if (frame) {
          yield frame.event;
          // ACK only after the original consumer has processed the yielded frame.
          if (!this.#closed && !signal?.aborted) this.#send({ kind: 'ack', requestId: id, sequence: frame.sequence, generation: frame.generation });
        } else if (stream.done) {
          if (stream.error) throw stream.error;
          return;
        } else await new Promise(resolve => { stream.wake = resolve; });
      }
    } finally {
      signal?.removeEventListener('abort', cancel);
      this.#streams.delete(id);
      if (!this.#closed) this.#send({ kind: 'unsubscribe', requestId: id });
    }
  }
  close() {
    if (this.#closed) return;
    for (const [id, item] of this.#pending) { this.#send({ kind: 'cancel', requestId: id }); item.clean(); item.reject(aborted()); }
    this.#pending.clear();
    for (const [id, item] of this.#streams) { this.#send({ kind: 'unsubscribe', requestId: id }); item.done = true; item.queue.length = 0; item.wake?.(); }
    this.#streams.clear(); this.#closed = true; this.#channel.onmessage = null;
  }
}

/** Keep original positional Remote contracts; never accept a second session from renderer data. */
export function createDocumentRemote(bridge, sessionId, supervise) {
  const check = id => { if (id !== sessionId) throw new Error('Document preview session mismatch'); };
  const invoke = (namespace, method, id, args, signal) => { check(id); return bridge.call(namespace, method, args, signal); };
  return {
    $stream: supervise,
    workspaceFiles: {
      stat: (id, path, signal) => invoke('workspaceFiles', 'stat', id, { path }, signal),
      read: (id, path, range, signal) => invoke('workspaceFiles', 'read', id, { path, range }, signal),
      readBytes: (id, path, options, signal) => invoke('workspaceFiles', 'readBytes', id, { path, options }, signal),
      list: (id, path, signal) => invoke('workspaceFiles', 'list', id, { path }, signal),
      changes: (id, path, signal) => { check(id); return bridge.changes(path, signal); },
    },
    officeToPdf: {
      render: (id, path, priority, signal) => invoke('officeToPdf', 'render', id, { path, priority }, signal),
      generation: signal => bridge.call('officeToPdf', 'generation', {}, signal),
    },
  };
}
