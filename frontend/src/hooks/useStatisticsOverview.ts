/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useCallback, useEffect, useState } from 'react'
import {
  StatisticsFilters,
  StatisticsOverview,
  statisticsApi,
} from '../services/statistics'

interface OverviewState {
  data: StatisticsOverview | null
  loading: boolean
  error: string | null
}

/**
 * Loads the cohort statistics overview for the given filters, reloading
 * whenever the serialized filter set changes.
 */
export function useStatisticsOverview(
  filters: StatisticsFilters
): OverviewState & {
  reload: () => void
} {
  const [state, setState] = useState<OverviewState>({
    data: null,
    loading: true,
    error: null,
  })

  const filtersKey = JSON.stringify(filters)

  const load = useCallback(() => {
    let cancelled = false
    setState(prev => ({ ...prev, loading: true, error: null }))
    statisticsApi
      .getOverview(filters)
      .then(data => {
        if (!cancelled) {
          setState({ data, loading: false, error: null })
        }
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          const message =
            err instanceof Error ? err.message : 'Failed to load statistics'
          setState({ data: null, loading: false, error: message })
        }
      })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filtersKey])

  useEffect(() => {
    const cleanup = load()
    return cleanup
  }, [load])

  return { ...state, reload: load }
}
