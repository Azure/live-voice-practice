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

  // Load scenarios on mount
  useEffect(() => {
    // Load server scenarios
    api
      .getScenarios()
      .then(setScenarios)
      .finally(() => setLoading(false))
  }, [])

  const refreshScenarios = useCallback(async () => {
    setLoading(true)
    try {
      const updatedScenarios = await api.getScenarios()
      setScenarios(updatedScenarios)
    } finally {
      setLoading(false)
    }
  }, [])

  return {
    scenarios,
    selectedScenario,
    setSelectedScenario,
    loading,
    refreshScenarios,
  }
}
