/**
 * What the browser half registers, with which nav identity, and that every
 * contribution leaves with the plugin fiber.
 */

import { Context } from '@deepseek-ai/cordis'
import { describe, expect, it } from 'vitest'
import { LocaleRuntime } from '@deepseek-ai/dsh-client-locale/client'
import { SlotRegistry } from '@deepseek-ai/dsh-client-ui-renderer/client'
import { resolveSlotLabel } from '@deepseek-ai/dsh-client-ui-slots'
import { apply, inject, NS } from '../src/client/index.ts'

/** One client bench with the slot ledger and the locale service. */
async function bench() {
  const ctx = new Context()
  await ctx.plugin(SlotRegistry).await()
  const locale = new LocaleRuntime(ctx)
  locale.setLocale('zh')
  ctx.provide('locale', locale)
  const slots = ctx.get('slots') as SlotRegistry
  slots.register({
    name: 'root',
    children: {
      'settings.section': { kind: 'list', scope: 'root' },
      'settings.section.icon': { kind: 'list', scope: 'root', inline: true },
    },
  } as never, () => null)
  return { ctx, slots }
}

describe('device-interconnect client apply', () => {
  it('declares the services it uses', () => {
    expect(inject).toEqual(['slots', 'locale'])
  })

  it('registers the settings section and its icon under the localized nav label', async () => {
    const { ctx, slots } = await bench()
    const fiber = ctx.plugin({ inject: [...inject], apply })
    await fiber.await()
    const section = slots.entries('settings.section')[0]
    expect(section?.options).toMatchObject({ id: 'device-interconnect', order: 15 })
    expect(resolveSlotLabel(section?.options.label)).toBe('设备互联')
    expect(section?.locale).toBe(NS)
    const icon = slots.entries('settings.section.icon')[0]
    expect(icon?.options).toMatchObject({ id: 'device-interconnect' })
    expect(resolveSlotLabel(icon?.options.label)).toBe('设备互联')
    const face = (section?.inject as () => { hooks: { deviceInterconnect: unknown }; actions: Record<string, unknown> })()
    expect(typeof (face.hooks.deviceInterconnect as { getSnapshot?: unknown }).getSnapshot).toBe('function')
    for (const action of [
      'open', 'close', 'refresh', 'setEnabled', 'setTunnelEnabled', 'edit', 'toggle', 'selectTunnelProvider',
      'provision', 'save', 'regeneratePairing', 'revokeDevice', 'deleteDevice', 'dismissNotice',
    ]) {
      expect(typeof face.actions[action]).toBe('function')
    }
    // The inject face is rebuilt per render but hands out the same observable.
    const again = (section?.inject as () => { hooks: { deviceInterconnect: unknown } })()
    expect(again.hooks.deviceInterconnect).toBe(face.hooks.deviceInterconnect)
    await fiber.dispose()
  })

  it('removes both contributions on disposal', async () => {
    const { ctx, slots } = await bench()
    const fiber = ctx.plugin({ inject: [...inject], apply })
    await fiber.await()
    expect(slots.entries('settings.section')).toHaveLength(1)
    expect(slots.entries('settings.section.icon')).toHaveLength(1)
    await fiber.dispose()
    expect(slots.entries('settings.section')).toHaveLength(0)
    expect(slots.entries('settings.section.icon')).toHaveLength(0)
  })
})
