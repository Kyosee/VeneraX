import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'

const sourcePath = new URL('../src/utils/source.ts', import.meta.url)
const source = await readFile(sourcePath, 'utf8')
const { outputText } = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2022,
    target: ts.ScriptTarget.ES2022,
  },
})
const moduleUrl = `data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`
const { normalizeComicSources, resolveSourceKey } = await import(moduleUrl)

const deduped = normalizeComicSources([
  { name: 'comic_source/copy_manga.js', key: 'copy_manga (1)' },
  { name: 'comic_source/copy_manga.js', key: 'copy_manga (2)' },
  { name: 'comic_source/ehentai.js', key: 'ehentai' },
  { name: 'comic_source/copy_manga.data', key: 'copy_manga.data' },
])

assert.equal(deduped.length, 2)
assert.deepEqual(deduped.map(item => item.key).sort(), ['copy_manga (1)', 'ehentai'])
assert.equal(
  resolveSourceKey({ type: 557997769 }, [{ key: 'copy_manga (1)', canonicalKey: 'copy_manga' }]),
  'copy_manga (1)',
)
assert.equal(resolveSourceKey({ sourceKey: 'copy_manga' }, [{ key: 'copy_manga (1)', canonicalKey: 'copy_manga' }]), 'copy_manga (1)')

console.log('source utils verification passed')
