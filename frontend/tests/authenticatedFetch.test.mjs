import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import ts from 'typescript'

async function loadTransport(fetch) {
  globalThis.window = { fetch }
  const source = await readFile(
    new URL('../src/services/authenticatedFetch.ts', import.meta.url),
    'utf8'
  )
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2022,
    },
  })
  return import(
    `data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}#${Math.random()}`
  )
}

test('exchanges a provider token in a POST body, then uses cookies without token headers or URLs', async () => {
  const calls = []
  const transport = await loadTransport(async (url, init) => {
    calls.push({ url, init })
    if (url === '/api/me') return Response.json({ authenticated: false })
    if (url === '/.auth/me')
      return Response.json([{ access_token: 'fixture-token' }])
    return Response.json({ ok: true })
  })
  await Promise.all([
    transport.authenticatedFetch('/api/scenarios'),
    transport.authenticatedFetch('/api/conversations'),
  ])
  const exchange = calls.filter(call => call.url === '/api/auth/session')
  assert.equal(exchange.length, 1)
  assert.equal(exchange[0].init.method, 'POST')
  assert.deepEqual(JSON.parse(exchange[0].init.body), {
    access_token: 'fixture-token',
  })
  assert.ok(calls.every(call => !String(call.url).includes('fixture-token')))
  assert.equal(
    calls.find(call => call.url === '/api/scenarios').init,
    undefined
  )
})

test('does not send protected requests when provider credentials are absent', async () => {
  const calls = []
  const transport = await loadTransport(async url => {
    calls.push(url)
    if (url === '/api/me') return Response.json({ authenticated: false })
    return Response.json([])
  })
  await assert.rejects(transport.authenticatedFetch('/api/analyze'), /Sign in/)
  assert.deepEqual(calls, ['/api/me', '/.auth/me'])
})

test('reuses an existing cookie and resets the bootstrap after an unauthorized response', async () => {
  let probes = 0
  const transport = await loadTransport(async url => {
    if (url === '/api/me') {
      probes++
      return Response.json({ authenticated: true })
    }
    return new Response(null, { status: 401 })
  })
  await transport.authenticatedFetch('/api/scenarios')
  await transport.authenticatedFetch('/api/scenarios')
  assert.equal(probes, 4)
})
