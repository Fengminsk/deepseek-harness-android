/**
 * Settings-navigation glyph of the Device Interconnect section: a laptop and a
 * phone joined by a link, drawn in the shared product icon geometry (16-unit
 * view box, 1-unit strokes, currentColor so it follows the nav row's color).
 */

import type { PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'

/**
 * Render the section's navigation glyph.
 * @param props - the requested square edge and whether the section is selected.
 * @returns the inline SVG.
 */
export function SectionIcon({ size, active }: PropsRuntime<'settings.section.icon'>) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden="true"
      data-active={active} data-device-interconnect-icon="">
      <rect x="1.5" y="3.1" width="8.6" height="6.2" rx="1.1" stroke="currentColor" strokeWidth="1" />
      <path d="M3.4 11.4h4.8" stroke="currentColor" strokeWidth="1" strokeLinecap="round" />
      <path d="M5.8 9.3v2.1" stroke="currentColor" strokeWidth="1" strokeLinecap="round" />
      <rect x="10.5" y="5.4" width="4" height="7.7" rx="1.1" stroke="currentColor" strokeWidth="1" />
      <path d="M11.9 11.6h1.2" stroke="currentColor" strokeWidth="1" strokeLinecap="round" />
      <circle cx="9.6" cy="6.6" r="0.9" fill="currentColor" />
    </svg>
  )
}
