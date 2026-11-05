let sessionReady: Promise<void> | undefined

export async function ensureBrowserSession(force = false): Promise<void> {
  if (force) sessionReady = undefined
  if (!sessionReady) {
    sessionReady = (async () => {
      const current = await window.fetch('/api/me', { cache: 'no-store' })
      if (current.ok && (await current.json()).authenticated) return
      const response = await window.fetch('/.auth/me', { cache: 'no-store' })
      if (!response.ok) throw new Error('Sign in is required')
      const identities: { access_token?: string }[] = await response.json()
      const token = identities[0]?.access_token
      if (!token)
        throw new Error('Sign in with the delegated API scope is required')
      const exchange = await window.fetch('/api/auth/session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ access_token: token }),
      })
      if (!exchange.ok)
        throw new Error('Unable to establish an authenticated session')
    })().catch(error => {
      sessionReady = undefined
      throw error
    })
  }
  return sessionReady
}

export async function authenticatedFetch(
  input: RequestInfo | URL,
  init?: RequestInit
): Promise<Response> {
  await ensureBrowserSession()
  let response = await window.fetch(input, init)
  if (response.status === 401) {
    await ensureBrowserSession(true)
    response = await window.fetch(input, init)
    if (response.status === 401) sessionReady = undefined
  }
  return response
}
