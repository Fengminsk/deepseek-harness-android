import { createHash } from 'node:crypto'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import ts from 'typescript'

const sources = ['secret-rule', 'credential-scanner', 'credential-masks', 'credential-formats', 'format-tables']
const digest = value => createHash('sha256').update(value).digest('hex')

/** Ship the original pure matcher, without loading the Web renderer in Node. */
export async function stageSecretMask(destination) {
  const root = resolve(import.meta.dirname, '../../..')
  const directory = join(destination, 'secret-mask')
  await mkdir(directory, { recursive: true })
  const manifest = []
  for (const name of sources) {
    const source = `packages/client/ui-secret-mask/src/client/${name}.ts`
    const content = await readFile(join(root, source), 'utf8')
    const compiled = ts.transpileModule(content, {
      fileName: source,
      compilerOptions: {
        target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext,
        rewriteRelativeImportExtensions: true,
      },
      reportDiagnostics: true,
    })
    const errors = compiled.diagnostics?.filter(item => item.category === ts.DiagnosticCategory.Error) ?? []
    if (errors.length) throw new Error(`Unable to compile original secret matcher: ${source}`)
    // New runtime dependencies must be reviewed rather than silently copied.
    const ast = ts.createSourceFile(`${name}.js`, compiled.outputText, ts.ScriptTarget.ES2022, true, ts.ScriptKind.JS)
    for (const statement of ast.statements) {
      if (!ts.isImportDeclaration(statement) && !ts.isExportDeclaration(statement)) continue
      const specifier = statement.moduleSpecifier
      if (!specifier || !ts.isStringLiteral(specifier)) continue
      if (!sources.some(entry => specifier.text === `./${entry}.js`)) {
        throw new Error(`Unexpected original secret matcher dependency in ${source}`)
      }
    }
    const output = `// Generated from ${source}; do not edit.\n${compiled.outputText}`
    await writeFile(join(directory, `${name}.js`), output)
    manifest.push({ source, sourceSha256: digest(content), file: `${name}.js`, sha256: digest(output) })
  }
  await writeFile(join(directory, 'package.json'), '{"type":"module"}\n')
  await writeFile(join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
}
