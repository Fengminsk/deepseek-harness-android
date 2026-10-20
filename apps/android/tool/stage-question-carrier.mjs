import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import ts from 'typescript'

/** Compile the existing Web question lifecycle for the Android carrier without forking its policy. */
export async function stageQuestionCarrier(destination) {
  const root = resolve(import.meta.dirname, '../../..')
  const source = join(root, 'packages/client/ui-user-questions/src/client/contract/slots.ts')
  const compiled = ts.transpileModule(await readFile(source, 'utf8'), {
    fileName: source,
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
    reportDiagnostics: true,
  })
  const errors = compiled.diagnostics?.filter(item => item.category === ts.DiagnosticCategory.Error) ?? []
  if (errors.length) throw new Error(ts.formatDiagnosticsWithColorAndContext(errors, {
    getCanonicalFileName: file => file, getCurrentDirectory: () => root, getNewLine: () => '\n',
  }))
  await mkdir(destination, { recursive: true })
  await writeFile(join(destination, 'question-carrier.mjs'),
    '// Generated from packages/client/ui-user-questions/src/client/contract/slots.ts.\n' + compiled.outputText)
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.filename)) {
  await stageQuestionCarrier(resolve(import.meta.dirname, '../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime'))
}
