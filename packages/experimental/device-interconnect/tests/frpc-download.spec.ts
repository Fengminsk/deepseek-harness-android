/**
 * frpc download and version check: URL mapping, the installed file, and the
 * refusal of a binary that does not report itself as the SakuraFrp build.
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { downloadFrpc, frpcDownloadUrl } from '../src/host/frpc-download.ts'
import { frpcInstallPath } from '../src/host/tunnel.ts'

const directories: string[] = []

afterEach(async () => {
  await Promise.all(directories.splice(0).map(directory => rm(directory, { recursive: true, force: true })))
})

/** Create one temporary data directory. */
async function dataDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-device-interconnect-frpc-dl-'))
  directories.push(directory)
  return directory
}

/** A fetch double returning the given bytes. */
function bytesFetch(bytes: Uint8Array, status = 200): typeof fetch {
  return async () => new Response(bytes.slice().buffer as ArrayBuffer, { status })
}

describe('frpc download URL', () => {
  it('maps the supported platforms', () => {
    expect(frpcDownloadUrl('win32', 'x64')).toBe('https://getfr.sh/d/frpc_windows_amd64.exe')
    expect(frpcDownloadUrl('win32', 'arm64')).toBe('https://getfr.sh/d/frpc_windows_arm64.exe')
    expect(frpcDownloadUrl('linux', 'x64')).toBe('https://getfr.sh/d/frpc_linux_amd64')
    expect(frpcDownloadUrl('linux', 'arm64')).toBe('https://getfr.sh/d/frpc_linux_arm64')
    expect(frpcDownloadUrl('darwin', 'x64')).toBe('https://getfr.sh/d/frpc_darwin_amd64')
    expect(frpcDownloadUrl('darwin', 'arm64')).toBe('https://getfr.sh/d/frpc_darwin_arm64')
    expect(frpcDownloadUrl('freebsd', 'x64')).toBeUndefined()
    expect(frpcDownloadUrl('win32', 'ia32')).toBeUndefined()
  })
})

describe('downloadFrpc', () => {
  it('installs the binary and keeps the SakuraFrp version', async () => {
    const dataDir = await dataDirectory()
    const result = await downloadFrpc({
      dataDir,
      platform: 'win32',
      arch: 'x64',
      fetch: bytesFetch(new Uint8Array([1, 2, 3])),
      versionCheck: async () => 'frpc version 0.51.0-sakura-4\n',
    })
    expect(result).toEqual({ path: frpcInstallPath(dataDir, 'win32'), version: 'frpc version 0.51.0-sakura-4' })
    expect(existsSync(result.path)).toBe(true)
    expect([...await readFile(result.path)]).toEqual([1, 2, 3])
  })

  it('refuses a binary that is not the SakuraFrp build', async () => {
    const dataDir = await dataDirectory()
    await expect(downloadFrpc({
      dataDir,
      platform: 'win32',
      arch: 'x64',
      fetch: bytesFetch(new Uint8Array([1])),
      versionCheck: async () => 'frpc version 0.61.0',
    })).rejects.toMatchObject({ code: 'frpc-version-invalid', steps: [] })
  })

  it('reports a failed download, an empty body, and an unsupported platform', async () => {
    const dataDir = await dataDirectory()
    await expect(downloadFrpc({ dataDir, platform: 'win32', arch: 'x64', fetch: bytesFetch(new Uint8Array(), 500) }))
      .rejects.toMatchObject({ code: 'frpc-download-failed' })
    await expect(downloadFrpc({ dataDir, platform: 'win32', arch: 'x64', fetch: bytesFetch(new Uint8Array()) }))
      .rejects.toMatchObject({ code: 'frpc-download-failed' })
    const network: typeof fetch = () => Promise.reject(new Error('offline'))
    await expect(downloadFrpc({ dataDir, platform: 'win32', arch: 'x64', fetch: network }))
      .rejects.toMatchObject({ code: 'frpc-download-failed' })
    await expect(downloadFrpc({ dataDir, platform: 'freebsd', arch: 'x64', fetch: bytesFetch(new Uint8Array([1])) }))
      .rejects.toMatchObject({ code: 'frpc-unsupported-platform' })
  })

  it('reports a version check that cannot run', async () => {
    const dataDir = await dataDirectory()
    const check = vi.fn(async () => { throw new Error('exec failed') })
    await expect(downloadFrpc({
      dataDir,
      platform: 'win32',
      arch: 'x64',
      fetch: bytesFetch(new Uint8Array([1])),
      versionCheck: check,
    })).rejects.toThrow('exec failed')
  })
})
