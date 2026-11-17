/**
 * Browser half of the Device Interconnect bundle: it registers the Settings
 * section, its navigation icon, its dictionaries, and the controller that
 * drives the page's polling.
 * @module @deepseek-ai/dsh-device-interconnect/client
 */

import type { Context as ClientContext } from '@deepseek-ai/cordis'
// Type-only: pulls the locale plugin's Context merge (ctx.locale) into this program.
import type {} from '@deepseek-ai/dsh-client-locale/client'
// Type-only: pulls the settings slot declarations and their owner props.
import type {} from '@deepseek-ai/dsh-client-ui-settings/client'
// Type-only: pulls the renderer's Context merge (ctx.slots) into this program.
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-slots'
import { DeviceInterconnectController } from './controller.ts'
import { DeviceInterconnectSection } from './DeviceInterconnectSection.tsx'
import type { DeviceInterconnectFace } from './DeviceInterconnectSection.tsx'
import { de, en, es, fr, ja, pt, ru, zh, type DeviceInterconnectLocaleKey } from './locales.ts'
import { SectionIcon } from './SectionIcon.tsx'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** The Device Interconnect Settings page copy. */
    'settings.deviceInterconnect': DeviceInterconnectLocaleKey
  }
}

/** Dictionary namespace owned by this plugin. */
export const NS = 'settings.deviceInterconnect'

/** Minimum bridge actions the page can offer without a settings document. */
export const inject = ['slots', 'locale']

/**
 * Register the Device Interconnect settings section, its icon, its
 * dictionaries, and its polling controller.
 * @param ctx - client root context.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(NS, { zh, en, ja, es, fr, de, ru, pt }), 'device-interconnect: copy dictionaries')
  const controller = new DeviceInterconnectController()
  ctx.effect(() => () => { controller.close() }, 'device-interconnect: polling driver')
  const t = ctx.locale.bind(NS)
  const injected = (): DeviceInterconnectFace => ({
    hooks: { deviceInterconnect: controller.store },
    actions: controller.actions,
  })
  ctx.slots.inject('settings.section', () => ctx.slots.register({
    name: 'settings.section',
    id: 'device-interconnect',
    order: 15,
    label: () => t('nav'),
    locale: NS,
    inject: injected,
  }, DeviceInterconnectSection))
  ctx.slots.inject('settings.section.icon', () => ctx.slots.register({
    name: 'settings.section.icon',
    id: 'device-interconnect',
    label: () => t('nav'),
    locale: NS,
  }, SectionIcon))
}
