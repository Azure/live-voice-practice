/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useEffect, useState } from 'react'
import {
  TraineesQuery,
  TraineesResponse,
  statisticsApi,
} from '../services/statistics'

interface TraineesState {
  data: TraineesResponse | null
  loading: boolean
  error: string | null
}

/** Loads the paginated, sortable per-trainee aggregates for the given query. */
export function useStatisticsTrainees(query: TraineesQuery): TraineesState {
  const [state, setState] = useState<TraineesState>({
    data: null,
    loading: true,
    error: null,
  })

  const queryKey = JSON.stringify(query)

  useEffect(() => {
    let cancelled = false
    setState(prev => ({ ...prev, loading: true, error: null }))
    statisticsApi
      .getTrainees(query)
      .then(data => {
        if (!cancelled) {
          setState({ data, loading: false, error: null })
        }
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          const message =
            err instanceof Error ? err.message : 'Failed to load trainees'
          setState({ data: null, loading: false, error: message })
        }
      })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryKey])

  return state
}
