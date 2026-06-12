/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { makeStyles, tokens } from '@fluentui/react-components'
import type { ReactElement } from 'react'
import { Bar, BarChart, CartesianGrid, Tooltip, XAxis, YAxis } from 'recharts'
import { StatisticsOverview } from '../../services/statistics'
import { ChartCard } from '../charts/ChartCard'
import { chartColors } from '../charts/chartTheme'

const useStyles = makeStyles({
  grid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(360px, 1fr))',
    gap: tokens.spacingHorizontalL,
    marginTop: tokens.spacingVerticalL,
  },
})

export interface CohortChartsProps {
  data: StatisticsOverview | null
  loading: boolean
  scenarioNameById: Map<string, string>
}

/**
 * The cohort drill-down charts (scenario performance, weakest criteria, score
 * distribution, drop-off). Each is rendered through the shared ChartCard.
 */
export function CohortCharts({
  data,
  loading,
  scenarioNameById,
}: CohortChartsProps): ReactElement {
  const styles = useStyles()

  const scenarioName = (id: string): string => scenarioNameById.get(id) ?? id

  const performance = (data?.performanceByScenario ?? []).map(row => ({
    ...row,
    scenarioName: scenarioName(row.scenarioId),
  }))
  const weakest = data?.weakestCriteria ?? []
  const distribution = data?.scoreDistribution ?? []
  const dropOff = (data?.dropOffByScenario ?? []).map(row => ({
    ...row,
    scenarioName: scenarioName(row.scenarioId),
  }))

  return (
    <div className={styles.grid}>
      <ChartCard
        title="Performance by scenario"
        subtitle="Average score (% of rubric max)"
        loading={loading}
        isEmpty={!loading && performance.length === 0}
      >
        <BarChart data={performance}>
          <CartesianGrid strokeDasharray="3 3" stroke={chartColors.grid} />
          <XAxis
            dataKey="scenarioName"
            stroke={chartColors.axis}
            fontSize={12}
          />
          <YAxis domain={[0, 100]} stroke={chartColors.axis} fontSize={12} />
          <Tooltip />
          <Bar
            dataKey="avgScorePercent"
            name="Avg score %"
            fill={chartColors.primary}
            radius={[4, 4, 0, 0]}
          />
        </BarChart>
      </ChartCard>

      <ChartCard
        title="Weakest criteria"
        subtitle="Lowest average criterion scores (% of scale)"
        loading={loading}
        isEmpty={!loading && weakest.length === 0}
      >
        <BarChart data={weakest} layout="vertical">
          <CartesianGrid strokeDasharray="3 3" stroke={chartColors.grid} />
          <XAxis
            type="number"
            domain={[0, 100]}
            stroke={chartColors.axis}
            fontSize={12}
          />
          <YAxis
            type="category"
            dataKey="name"
            width={140}
            stroke={chartColors.axis}
            fontSize={12}
          />
          <Tooltip />
          <Bar
            dataKey="avgScorePercent"
            name="Avg score %"
            fill={chartColors.accent}
            radius={[0, 4, 4, 0]}
          />
        </BarChart>
      </ChartCard>

      <ChartCard
        title="Score distribution"
        subtitle="Count of analyzed practices by score band (%)"
        loading={loading}
        isEmpty={!loading && distribution.every(bucket => bucket.count === 0)}
      >
        <BarChart data={distribution}>
          <CartesianGrid strokeDasharray="3 3" stroke={chartColors.grid} />
          <XAxis dataKey="bucket" stroke={chartColors.axis} fontSize={12} />
          <YAxis
            allowDecimals={false}
            stroke={chartColors.axis}
            fontSize={12}
          />
          <Tooltip />
          <Bar
            dataKey="count"
            name="Practices"
            fill={chartColors.secondary}
            radius={[4, 4, 0, 0]}
          />
        </BarChart>
      </ChartCard>

      <ChartCard
        title="Drop-off by scenario"
        subtitle="Started practices that were never analyzed (%)"
        loading={loading}
        isEmpty={!loading && dropOff.length === 0}
      >
        <BarChart data={dropOff}>
          <CartesianGrid strokeDasharray="3 3" stroke={chartColors.grid} />
          <XAxis
            dataKey="scenarioName"
            stroke={chartColors.axis}
            fontSize={12}
          />
          <YAxis domain={[0, 100]} stroke={chartColors.axis} fontSize={12} />
          <Tooltip />
          <Bar
            dataKey="dropOffPercent"
            name="Drop-off %"
            fill={chartColors.accent}
            radius={[4, 4, 0, 0]}
          />
        </BarChart>
      </ChartCard>
    </div>
  )
}
