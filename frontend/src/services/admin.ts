/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

// Admin content-management API client (scenarios, rubrics, transcripts, materials).
// All endpoints are trainer-gated server-side; non-trainers receive HTTP 403.

export type JsonDoc = Record<string, unknown>

export interface MaterialItem {
  name: string
}

export interface TranscriptDoc {
  transcriptId: string
  text: string
}

interface ApiError {
  error?: string
  details?: string[]
}

async function parseError(res: Response): Promise<Error> {
  let body: ApiError = {}
  try {
    body = await res.json()
  } catch {
    // non-JSON body; fall through to status-based message
  }
  const base = body.error ?? `HTTP ${res.status}`
  const details = body.details?.length ? `: ${body.details.join('; ')}` : ''
  return new Error(`${base}${details}`)
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url)
  if (!res.ok) throw await parseError(res)
  return res.json()
}

async function sendJson<T>(
  url: string,
  method: 'POST' | 'PUT',
  body: unknown
): Promise<T> {
  const res = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!res.ok) throw await parseError(res)
  return res.json()
}

async function remove(url: string): Promise<void> {
  const res = await fetch(url, { method: 'DELETE' })
  if (!res.ok) throw await parseError(res)
}

function documentCrud(resource: 'scenarios' | 'rubrics') {
  const base = `/api/admin/${resource}`
  return {
    async list(): Promise<JsonDoc[]> {
      const data = await getJson<{ items: JsonDoc[] }>(base)
      return data.items ?? []
    },
    get(id: string): Promise<JsonDoc> {
      return getJson<JsonDoc>(`${base}/${encodeURIComponent(id)}`)
    },
    create(doc: JsonDoc): Promise<JsonDoc> {
      return sendJson<JsonDoc>(base, 'POST', doc)
    },
    update(id: string, doc: JsonDoc): Promise<JsonDoc> {
      return sendJson<JsonDoc>(`${base}/${encodeURIComponent(id)}`, 'PUT', doc)
    },
    remove(id: string): Promise<void> {
      return remove(`${base}/${encodeURIComponent(id)}`)
    },
  }
}

export const adminApi = {
  scenarios: documentCrud('scenarios'),
  rubrics: documentCrud('rubrics'),

  transcripts: {
    async list(): Promise<string[]> {
      const data = await getJson<{ items: string[] }>('/api/admin/transcripts')
      return data.items ?? []
    },
    get(id: string): Promise<TranscriptDoc> {
      return getJson<TranscriptDoc>(
        `/api/admin/transcripts/${encodeURIComponent(id)}`
      )
    },
    create(
      transcriptId: string,
      text: string
    ): Promise<{ transcriptId: string }> {
      return sendJson('/api/admin/transcripts', 'POST', { transcriptId, text })
    },
    update(id: string, text: string): Promise<{ transcriptId: string }> {
      return sendJson(
        `/api/admin/transcripts/${encodeURIComponent(id)}`,
        'PUT',
        { text }
      )
    },
    remove(id: string): Promise<void> {
      return remove(`/api/admin/transcripts/${encodeURIComponent(id)}`)
    },
  },

  materials: {
    async list(): Promise<MaterialItem[]> {
      const data = await getJson<{ items: MaterialItem[] }>(
        '/api/admin/materials'
      )
      return data.items ?? []
    },
    async upload(
      file: File
    ): Promise<{ name: string; reindexTriggered: boolean }> {
      const form = new FormData()
      form.append('file', file)
      const res = await fetch('/api/admin/materials', {
        method: 'POST',
        body: form,
      })
      if (!res.ok) throw await parseError(res)
      return res.json()
    },
    remove(name: string): Promise<void> {
      return remove(`/api/admin/materials/${encodeURIComponent(name)}`)
    },
  },
}
