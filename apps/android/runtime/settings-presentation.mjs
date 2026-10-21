/** Add package artwork to App settings without changing the original form values or revisions. */
export function describeAndroidSettings(ctx) {
  const forms = ctx.settings.describe({ redactSecrets: true })
  const editor = ctx.get('configEditor')
  const packages = ctx.get('pluginPackages')
  if (editor === undefined || packages === undefined) return forms
  const entries = new Map(editor.configuration().map(({ entry }) => [entry.options.id, entry]))
  return forms.map(form => {
    const entry = entries.get(form.ns)
    if (entry === undefined) return form
    const base = entry.parent.tree.ctx.baseUrl
    const meta = base === undefined ? undefined : packages.metaOf(entry.options.name, base)
    return { ...form, display: { moduleName: entry.options.name, ...meta } }
  })
}
