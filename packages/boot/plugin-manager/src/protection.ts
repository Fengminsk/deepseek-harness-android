/** Entry identities affected by reserved modules, including their enclosing groups. */
import type { EntryOptions } from '@deepseek-ai/cordis-plugin-loader'
import type { PatchOptions } from '@deepseek-ai/cordis-plugin-include'

/** Collect reserved entries and ancestors from both original insertions and the current composition.
 * Original insertions matter when an overlay has replaced a group's children.
 * @param patches Profile patch layers.
 * @param rows Current composed or loader entries.
 * @param modules Exact module names owned by the host.
 * @param ownerId Optional entry id of the manager itself.
 * @returns Patch ids whose mutation can affect a reserved entry.
 */
export function protectedIds(
  patches: readonly PatchOptions[], rows: readonly EntryOptions[], modules: ReadonlySet<string>, ownerId?: string,
): Set<string> {
  const ids = new Set<string>()
  const visit = (entries: readonly EntryOptions[], ancestors: readonly string[] = []): void => {
    for (const row of entries) {
      const lineage = [...ancestors, row.id]
      if (modules.has(row.name) || row.id === ownerId) for (const id of lineage) ids.add(id)
      if (row.group && Array.isArray(row.config)) visit(row.config as EntryOptions[], lineage)
    }
  }
  visit(rows)
  for (const patch of patches) {
    if (patch.insert !== undefined) visit(patch.insert, patch.id === undefined ? [] : [patch.id])
    if (patch.group === true && Array.isArray(patch.config)) {
      visit(patch.config as EntryOptions[], patch.id === undefined ? [] : [patch.id])
    }
  }
  return ids
}

/** Whether a bundle adds, overrides, or replaces a reserved entry or one of its parents.
 * @param patches Uncomposed bundle patches; override-only bundles must not disappear in empty-root composition.
 * @param ids Reserved ids in the whole profile.
 * @param modules Reserved module names.
 * @returns Whether changing this layer could change a host-owned entry.
 */
export function affectsProtected(
  patches: readonly PatchOptions[], ids: ReadonlySet<string>, modules: ReadonlySet<string>,
): boolean {
  const touches = (rows: readonly unknown[]): boolean => rows.some((row) => {
    if (typeof row !== 'object' || row === null) return false
    return ('id' in row && typeof row.id === 'string' && ids.has(row.id))
      || ('name' in row && typeof row.name === 'string' && modules.has(row.name))
      || ('group' in row && row.group === true && 'config' in row && Array.isArray(row.config) && touches(row.config))
  })
  return patches.some(patch =>
    (patch.id !== undefined && ids.has(patch.id))
    || (patch.name !== undefined && modules.has(patch.name))
    || (patch.insert !== undefined && touches(patch.insert))
    || (Array.isArray(patch.config) && touches(patch.config)))
}
