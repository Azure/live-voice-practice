/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useCallback, useEffect, useState } from 'react'
import { api } from '../services/api'
import { Scenario } from '../types'

export function useScenarios() {
  const [scenarios, setScenarios] = useState<Scenario[]>([])
  const [selectedScenario, setSelectedScenario] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  // Load scenarios on mount
  useEffect(() => {
    // Load server scenarios
    api
      .getScenarios()
      .then((s) => {
        setScenarios(s)
        setError(null)
      })
      .catch((err: Error) => {
        // Surface backend auth/IMDS failures instead of silently rendering an
        // empty list. The error message includes the diagnostic code so ops
        // can correlate it with backend logs.
        console.error('Failed to load scenarios:', err)
        setError(err.message ?? 'Failed to load scenarios')
        setScenarios([])
      })
      .finally(() => setLoading(false))
  }, [])

  const refreshScenarios = useCallback(async () => {
    setLoading(true)
    try {
      const updatedScenarios = await api.getScenarios()
      setScenarios(updatedScenarios)
      setError(null)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to refresh scenarios'
      console.error('Failed to refresh scenarios:', err)
      setError(message)
      setScenarios([])
    } finally {
      setLoading(false)
    }
  }, [])

  return {
    scenarios,
    selectedScenario,
    setSelectedScenario,
    loading,
    error,
    refreshScenarios,
  }
}
