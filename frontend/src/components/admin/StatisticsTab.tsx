/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  MessageBar,
  MessageBarBody,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import type { ReactElement } from 'react'
import {
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import { useScenarios } from '../../hooks/useScenarios'
import { useStatisticsFilters } from '../../hooks/useStatisticsFilters'
import { useStatisticsOverview } from '../../hooks/useStatisticsOverview'
import { ChartCard } from '../charts/ChartCard'
import { chartColors } from '../charts/chartTheme'
import { CohortCharts } from './CohortCharts'
import { KpiCards } from './KpiCards'
import { StatisticsFiltersBar } from './StatisticsFiltersBar'
import { TraineesTable } from './TraineesTable'

const useStyles = makeStyles({
  charts: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(360px, 1fr))',
    gap: tokens.spacingHorizontalL,
  },
  notice: {
    marginBottom: tokens.spacingVerticalM,
  },
})

/**
 * Cohort overview view: shared filters, headline KPIs, and the practices /
 * average-score time series. All aggregation is server-side; this component
 * only renders the returned series.
 */
export function StatisticsTab(): ReactElement {
  const styles = useStyles()
  const { filters, setFilters } = useStatisticsFilters()
  const { scenarios } = useScenarios()
  const { data, loading, error } = useStatisticsOverview(filters)

  const practices = data?.practicesOverTime ?? []
  const scores = data?.averageScoreOverTime ?? []
  const scenarioNameById = new Map(scenarios.map(s => [s.id, s.name]))

  return (
    <div>
      <StatisticsFiltersBar
        filters={filters}
        scenarios={scenarios}
        onChange={setFilters}
      />

      {error && (
        <MessageBar intent="error" className={styles.notice}>
          <MessageBarBody>{error}</MessageBarBody>
        </MessageBar>
      )}

      {data?.windowCapped && (
        <MessageBar intent="warning" className={styles.notice}>
          <MessageBarBody>
            Results are capped to the most recent records; some older practices
            may be excluded.
          </MessageBarBody>
        </MessageBar>
      )}

      <KpiCards kpis={data?.kpis ?? null} loading={loading} />

      <div className={styles.charts}>
        <ChartCard
          title="Practices over time"
          subtitle="Completed practices per day"
          loading={loading}
          isEmpty={!loading && practices.length === 0}
        >
          <BarChart data={practices}>
            <CartesianGrid strokeDasharray="3 3" stroke={chartColors.grid} />
            <XAxis dataKey="date" stroke={chartColors.axis} fontSize={12} />
            <YAxis
              allowDecimals={false}
              stroke={chartColors.axis}
              fontSize={12}
            />
            <Tooltip />
            <Bar
              dataKey="count"
              name="Practices"
              fill={chartColors.primary}
              radius={[4, 4, 0, 0]}
            />
          </BarChart>
        </ChartCard>

        <ChartCard
          title="Average score over time"
          subtitle="Mean score (% of rubric max) per day"
          loading={loading}
          isEmpty={!loading && scores.length === 0}
        >
          <LineChart data={scores}>
            <CartesianGrid strokeDasharray="3 3" stroke={chartColors.grid} />
            <XAxis dataKey="date" stroke={chartColors.axis} fontSize={12} />
            <YAxis domain={[0, 100]} stroke={chartColors.axis} fontSize={12} />
            <Tooltip />
            <Line
              type="monotone"
              dataKey="avgScorePercent"
              name="Avg score %"
              stroke={chartColors.secondary}
              strokeWidth={2}
              dot={false}
            />
          </LineChart>
        </ChartCard>
      </div>

      <CohortCharts
        data={data}
        loading={loading}
        scenarioNameById={scenarioNameById}
      />

      <TraineesTable filters={filters} />
    </div>
  )
}
