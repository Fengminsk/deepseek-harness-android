import { CredentialProvider } from '@deepseek-ai/dsh-credentials'

/** Credentials stay in Android Keystore-backed storage, shared by both clients. */
export class AndroidCredentials extends CredentialProvider {
  constructor(ctx, transport) {
    super(ctx)
    this.transport = transport
    this.tail = Promise.resolve()
  }
  async resolve(ref) {
    const value = await this.transport.request('native.credentials.get', { name: `refs/${ref}` })
    return value === null ? undefined : { value, source: 'android-keystore' }
  }
  async describe(ref) { return { configured: (await this.resolve(ref)) !== undefined, writable: true, source: 'android-keystore' } }
  async set(ref, value) {
    await this.transport.request('native.credentials.set', { name: `refs/${ref}`, value })
    this.notifyUpdated(ref)
  }
  async unset(ref) {
    await this.transport.request('native.credentials.remove', { name: `refs/${ref}` })
    this.notifyUpdated(ref)
  }
  async readRecord(key) {
    const value = await this.transport.request('native.credentials.get', { name: `records/${key}` })
    return value === null ? undefined : JSON.parse(value)
  }
  async describeRecord(key) {
    const record = await this.readRecord(key)
    return { configured: record !== undefined, writable: true, ...(record === undefined ? {} : { kind: record.kind }) }
  }
  async listRecords() {
    const names = await this.transport.request('native.credentials.names', {})
    const records = []
    for (const name of names.filter(value => value.startsWith('records/'))) {
      const key = name.slice(8)
      const record = await this.readRecord(key)
      if (record !== undefined) records.push({ key, kind: record.kind })
    }
    return records
  }
  modifyRecord(key, mutate) {
    return this.serialize(async () => {
      const current = await this.readRecord(key)
      const next = await mutate(current)
      if (next === undefined) return current
      await this.transport.request('native.credentials.set', { name: `records/${key}`, value: JSON.stringify(next) })
      this.notifyRecordUpdated(key)
      return next
    })
  }
  deleteRecord(key) {
    return this.serialize(async () => {
      await this.transport.request('native.credentials.remove', { name: `records/${key}` })
      this.notifyRecordUpdated(key)
    })
  }
  serialize(action) {
    const operation = this.tail.then(action)
    this.tail = operation.then(() => {}, () => {})
    return operation
  }
}
