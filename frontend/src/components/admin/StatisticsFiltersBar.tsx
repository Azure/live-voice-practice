/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Dropdown,
  Field,
  Input,
  Option,
  Switch,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import type { ReactElement } from 'react'
import { StatisticsFilters } from '../../services/statistics'
import { Scenario } from '../../types'

const useStyles = makeStyles({
  bar: {
    display: 'flex',
    flexWrap: 'wrap',
    alignItems: 'flex-end',
    gap: tokens.spacingHorizontalL,
    marginBottom: tokens.spacingVerticalL,
  },
  field: {
    minWidth: '160px',
  },
})

export interface StatisticsFiltersBarProps {
  filters: StatisticsFilters
  scenarios: Scenario[]
  onChange: (partial: Partial<StatisticsFilters>) => void
}

/**
 * Shared filter controls (date range, scenario multi-select, status) used by
 * every statistics view. Stateless: it renders the current filters and reports
 * changes upward so the URL stays the single source of truth.
 */
export function StatisticsFiltersBar({
  filters,
  scenarios,
  onChange,
}: StatisticsFiltersBarProps): ReactElement {
  const styles = useStyles()
  const selectedScenarioIds = filters.scenarioIds ?? []
  const scenarioNameById = new Map(scenarios.map(s => [s.id, s.name]))

  return (
    <div className={styles.bar}>
      <Field label="From" className={styles.field}>
        <Input
          type="date"
          value={filters.from ?? ''}
          onChange={(_, data) => onChange({ from: data.value || undefined })}
        />
      </Field>
      <Field label="To" className={styles.field}>
        <Input
          type="date"
          value={filters.to ?? ''}
          onChange={(_, data) => onChange({ to: data.value || undefined })}
        />
      </Field>
      <Field label="Scenarios" className={styles.field}>
        <Dropdown
          multiselect
          placeholder="All scenarios"
          selectedOptions={selectedScenarioIds}
          value={selectedScenarioIds
            .map(id => scenarioNameById.get(id) ?? id)
            .join(', ')}
          onOptionSelect={(_, data) =>
            onChange({
              scenarioIds: data.selectedOptions.length
                ? data.selectedOptions
                : undefined,
            })
          }
        >
          {scenarios.map(scenario => (
            <Option key={scenario.id} value={scenario.id}>
              {scenario.name}
            </Option>
          ))}
        </Dropdown>
      </Field>
      <Field label="Include in-progress">
        <Switch
          checked={filters.includeInProgress ?? false}
          onChange={(_, data) => onChange({ includeInProgress: data.checked })}
        />
      </Field>
    </div>
  )
}
