/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useCallback, useEffect, useState } from 'react'
import { adminApi, JsonDoc, MaterialItem } from '../services/admin'

interface ListState<T> {
  items: T[]
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
}

function useList<T>(loader: () => Promise<T[]>): ListState<T> {
  const [items, setItems] = useState<T[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    try {
      setItems(await loader())
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load')
      setItems([])
    } finally {
      setLoading(false)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return { items, loading, error, refresh }
}

/** CRUD hook for scenario documents. */
export function useAdminScenarios() {
  const list = useList<JsonDoc>(() => adminApi.scenarios.list())
  return {
    ...list,
    get: adminApi.scenarios.get,
    create: adminApi.scenarios.create,
    update: adminApi.scenarios.update,
    remove: adminApi.scenarios.remove,
  }
}

/** CRUD hook for rubric documents. */
export function useAdminRubrics() {
  const list = useList<JsonDoc>(() => adminApi.rubrics.list())
  return {
    ...list,
    get: adminApi.rubrics.get,
    create: adminApi.rubrics.create,
    update: adminApi.rubrics.update,
    remove: adminApi.rubrics.remove,
  }
}

/** CRUD hook for transcript ids/text. */
export function useAdminTranscripts() {
  const list = useList<string>(() => adminApi.transcripts.list())
  return {
    ...list,
    get: adminApi.transcripts.get,
    create: adminApi.transcripts.create,
    update: adminApi.transcripts.update,
    remove: adminApi.transcripts.remove,
  }
}

/** CRUD hook for support-material PDFs. */
export function useAdminMaterials() {
  const list = useList<MaterialItem>(() => adminApi.materials.list())
  return {
    ...list,
    upload: adminApi.materials.upload,
    remove: adminApi.materials.remove,
  }
}
