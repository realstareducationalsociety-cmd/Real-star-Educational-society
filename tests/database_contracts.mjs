import assert from 'node:assert/strict'
import { readdir, readFile } from 'node:fs/promises'
import path from 'node:path'

const appRoot = path.resolve('app')
const migrationRoot = path.resolve('supabase/migrations')
const appFiles = []

async function visit(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name)
    if (entry.isDirectory()) await visit(file)
    else if (/\.(vue|ts|js)$/.test(entry.name)) appFiles.push(file)
  }
}

await visit(appRoot)
const appSources = await Promise.all(appFiles.map(file => readFile(file, 'utf8')))
const migrationFiles = (await readdir(migrationRoot))
  .filter(file => file.endsWith('.sql'))
  .sort()
const migrationSources = await Promise.all(
  migrationFiles.map(file => readFile(path.join(migrationRoot, file), 'utf8'))
)
const schema = migrationSources.join('\n')
const rpcNames = new Set()
const databaseObjects = new Set()

for (const source of appSources) {
  for (const match of source.matchAll(/\.rpc\s*\(\s*['"]([^'"]+)['"]/g)) rpcNames.add(match[1])
  for (const match of source.matchAll(/\.from\s*\(\s*['"]([^'"]+)['"]/g)) databaseObjects.add(match[1])
  if (source.includes('db.from(`${props.kind}s`)')) {
    databaseObjects.add('books')
    databaseObjects.add('chapters')
  }
}

for (const name of rpcNames) {
  const definition = new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.${name}\\s*\\(`,
    'i'
  )
  assert.match(schema, definition, `Missing local SQL function for frontend RPC ${name}`)
}

const apiMigration = migrationSources.find(source => source.includes('api text[]:=array['))
assert.ok(apiMigration, 'The final migration must define the supported RPC allowlist')
const allowlist = apiMigration.match(/api text\[\]:=array\[([\s\S]*?)\];/)?.[1] || ''
const allowedRpcNames = new Set([...allowlist.matchAll(/'([^']+)'/g)].map(match => match[1]))
for (const source of migrationSources) {
  for (const statement of source.matchAll(/grant\s+execute\s+on\s+function\s+([\s\S]*?)\s+to\s+authenticated\s*;/gi)) {
    for (const match of statement[1].matchAll(/public\.([a-z0-9_]+)\s*\(/gi)) {
      allowedRpcNames.add(match[1])
    }
  }
}
for (const name of rpcNames) {
  assert.ok(allowedRpcNames.has(name), `Frontend RPC ${name} is not granted by the final migration`)
}

for (const name of databaseObjects) {
  const relation = new RegExp(
    `create\\s+(?:(?:or\\s+replace)\\s+)?(?:table|view)\\s+(?:if\\s+not\\s+exists\\s+)?public\\.${name}\\b`,
    'i'
  )
  assert.match(schema, relation, `Missing local SQL table/view for frontend query ${name}`)
}

console.log(`PASS: ${rpcNames.size} frontend RPCs and ${databaseObjects.size} static tables/views match local migrations and RPC grants.`)
