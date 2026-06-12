/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useEffect, useState } from 'react'
import {
  StatisticsFilters,
  TraineeDetail,
  statisticsApi,
} from '../services/statistics'

interface TraineeDetailState {
  data: TraineeDetail | null
  loading: boolean
  error: string | null
}

/** Loads the detailed evolution payload for a single trainee identifier. */
export function useStatisticsTrainee(
  identifier: string | undefined,
  filters: StatisticsFilters
): TraineeDetailState {
  const [state, setState] = useState<TraineeDetailState>({
    data: null,
    loading: true,
    error: null,
  })

  const filtersKey = JSON.stringify(filters)

  useEffect(() => {
    if (!identifier) {
      setState({ data: null, loading: false, error: 'Missing trainee identifier' })
      return
    }
    let cancelled = false
    setState(prev => ({ ...prev, loading: true, error: null }))
    statisticsApi
      .getTraineeDetail(identifier, filters)
      .then(data => {
        if (!cancelled) {
          setState({ data, loading: false, error: null })
        }
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          const message =
            err instanceof Error ? err.message : 'Failed to load trainee'
          setState({ data: null, loading: false, error: message })
        }
      })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [identifier, filtersKey])

  return state
}
