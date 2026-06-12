/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useCallback, useMemo } from 'react'
import { useSearchParams } from 'react-router-dom'
import { StatisticsFilters } from '../services/statistics'

/**
 * Persists the shared statistics filter set in the URL query string so trainers
 * can bookmark and share a filtered dashboard view. Returns the parsed filters
 * plus a single setter that merges partial updates back into the query string.
 */
export function useStatisticsFilters(): {
  filters: StatisticsFilters
  setFilters: (partial: Partial<StatisticsFilters>) => void
} {
  const [searchParams, setSearchParams] = useSearchParams()

  const filters = useMemo<StatisticsFilters>(() => {
    const scenarioIds = searchParams.getAll('scenarioIds')
    const rubricIds = searchParams.getAll('rubricIds')
    return {
      from: searchParams.get('from') ?? undefined,
      to: searchParams.get('to') ?? undefined,
      scenarioIds: scenarioIds.length ? scenarioIds : undefined,
      rubricIds: rubricIds.length ? rubricIds : undefined,
      includeInProgress: searchParams.get('includeInProgress') === 'true',
    }
  }, [searchParams])

  const setFilters = useCallback(
    (partial: Partial<StatisticsFilters>) => {
      setSearchParams(
        prev => {
          const next = new URLSearchParams(prev)
          const merged: StatisticsFilters = { ...filters, ...partial }

          next.delete('from')
          next.delete('to')
          next.delete('scenarioIds')
          next.delete('rubricIds')
          next.delete('includeInProgress')

          if (merged.from) next.set('from', merged.from)
          if (merged.to) next.set('to', merged.to)
          for (const id of merged.scenarioIds ?? [])
            next.append('scenarioIds', id)
          for (const id of merged.rubricIds ?? []) next.append('rubricIds', id)
          if (merged.includeInProgress) next.set('includeInProgress', 'true')

          return next
        },
        { replace: true }
      )
    },
    [filters, setSearchParams]
  )

  return { filters, setFilters }
}
