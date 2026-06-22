/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { makeStyles, tokens } from '@fluentui/react-components'
import type { ReactElement } from 'react'
import { Bar, BarChart, CartesianGrid, Cell, Tooltip, XAxis, YAxis } from 'recharts'
import { StatisticsOverview } from '../../services/statistics'
import { ChartCard } from '../charts/ChartCard'
import { chartColors, inverseScoreColor, scoreColor } from '../charts/chartTheme'

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
        info="Compares scenarios by average AI evaluation score for analyzed practices. Scores are normalized to percent of the rubric maximum, so higher bars indicate stronger trainee performance for that scenario."
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
            maxBarSize={48}
            radius={[4, 4, 0, 0]}
          >
            {performance.map(row => (
              <Cell
                key={row.scenarioId}
                fill={scoreColor(row.avgScorePercent)}
              />
            ))}
          </Bar>
        </BarChart>
      </ChartCard>

      <ChartCard
        title="Weakest criteria"
        subtitle="Lowest average criterion scores (% of scale)"
        info="Highlights the rubric criteria with the lowest average scores across analyzed practices. Use this to find skills that need coaching, such as empathy, clarity, or resolution completeness."
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
            barSize={24}
            radius={[0, 4, 4, 0]}
          >
            {weakest.map(row => (
              <Cell key={row.name} fill={scoreColor(row.avgScorePercent)} />
            ))}
          </Bar>
        </BarChart>
      </ChartCard>

      <ChartCard
        title="Score distribution"
        subtitle="Count of analyzed practices by score band (%)"
        info="Groups analyzed practices into score ranges, such as 20-30 or 80-90. This helps show whether results are clustered low, mixed, or trending toward stronger performance."
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
            maxBarSize={48}
            radius={[4, 4, 0, 0]}
          >
            {distribution.map(bucket => {
              const [lower, upper] = bucket.bucket.split('-').map(Number)
              const midpoint = Number.isFinite(upper)
                ? (lower + upper) / 2
                : lower
              return (
                <Cell key={bucket.bucket} fill={scoreColor(midpoint)} />
              )
            })}
          </Bar>
        </BarChart>
      </ChartCard>

      <ChartCard
        title="Drop-off by scenario"
        subtitle="Started practices that were never analyzed (%)"
        info="Shows the share of started practices that did not produce an analysis result for each scenario. High drop-off can mean users abandoned the session, audio/scoring failed, or the conversation ended before analysis completed."
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
            maxBarSize={48}
            radius={[4, 4, 0, 0]}
          >
            {dropOff.map(row => (
              <Cell
                key={row.scenarioId}
                fill={inverseScoreColor(row.dropOffPercent)}
              />
            ))}
          </Bar>
        </BarChart>
      </ChartCard>
    </div>
  )
}
