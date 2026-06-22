/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Link as FluentLink,
  MessageBar,
  MessageBarBody,
  Spinner,
  Table,
  TableBody,
  TableCell,
  TableHeader,
  TableHeaderCell,
  TableRow,
  Text,
  Title2,
  Title3,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import type { ReactElement } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Line,
  LineChart,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import { useScenarios } from '../../hooks/useScenarios'
import { useStatisticsFilters } from '../../hooks/useStatisticsFilters'
import { useStatisticsTrainee } from '../../hooks/useStatisticsTrainee'
import { ChartCard } from '../charts/ChartCard'
import { chartColors, scoreColor } from '../charts/chartTheme'

const useStyles = makeStyles({
  root: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalL,
  },
  header: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXXS,
  },
  totals: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))',
    gap: tokens.spacingHorizontalL,
  },
  totalCard: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXXS,
    backgroundColor: tokens.colorNeutralBackground1,
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    borderRadius: tokens.borderRadiusLarge,
    padding: tokens.spacingVerticalL,
  },
  charts: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(360px, 1fr))',
    gap: tokens.spacingHorizontalL,
  },
  recommendations: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
    paddingLeft: tokens.spacingHorizontalL,
    margin: 0,
  },
})

function formatPercent(value: number | null): string {
  return value === null ? '—' : `${value}%`
}

function formatDate(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleDateString()
}

/**
 * Per-trainee evolution view: totals, score-over-time, per-criterion averages,
 * scenario breakdown, and deduplicated recent recommendations. All numbers come
 * from the backend; this component only renders them.
 */
export function TraineeDetail(): ReactElement {
  const styles = useStyles()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { filters } = useStatisticsFilters()
  const { scenarios } = useScenarios()
  const { data, loading, error } = useStatisticsTrainee(id, filters)

  const scenarioName = (scenarioId: string): string =>
    scenarios.find(s => s.id === scenarioId)?.name ?? scenarioId

  if (loading) {
    return <Spinner label="Loading trainee…" />
  }

  if (error || !data) {
    return (
      <div className={styles.root}>
        <FluentLink onClick={() => navigate('/admin')}>
          ← Back to statistics
        </FluentLink>
        <MessageBar intent="error">
          <MessageBarBody>{error ?? 'Trainee not found.'}</MessageBarBody>
        </MessageBar>
      </div>
    )
  }

  const scoreSeries = data.scoreTimeSeries.map(point => ({
    ...point,
    date: formatDate(point.date),
  }))
  const latestScore =
    scoreSeries.length > 0
      ? scoreSeries[scoreSeries.length - 1].scorePercent
      : data.totals.avgScorePercent
  const scenarioBreakdown = data.scenarioBreakdown.map(row => ({
    ...row,
    scenarioName: scenarioName(row.scenarioId),
  }))

  return (
    <div className={styles.root}>
      <FluentLink onClick={() => navigate('/admin')}>
        ← Back to statistics
      </FluentLink>
      <div className={styles.header}>
        <Title2>{data.displayName}</Title2>
        <Text size={200}>Practice evolution across the selected filters.</Text>
      </div>

      <div className={styles.totals}>
        <div className={styles.totalCard}>
          <Text size={200}>Practices</Text>
          <Title3>{data.totals.practices}</Title3>
        </div>
        <div className={styles.totalCard}>
          <Text size={200}>Analyzed</Text>
          <Title3>{data.totals.analyzedPractices}</Title3>
        </div>
        <div className={styles.totalCard}>
          <Text size={200}>Average score</Text>
          <Title3>{formatPercent(data.totals.avgScorePercent)}</Title3>
        </div>
        <div className={styles.totalCard}>
          <Text size={200}>Pass rate</Text>
          <Title3>{formatPercent(data.totals.passRatePercent)}</Title3>
        </div>
      </div>

      <div className={styles.charts}>
        <ChartCard
          title="Score over time"
          subtitle="Score (% of rubric max) per practice"
          info="Shows this trainee's score for each analyzed practice over time. Each point comes from the AI evaluation result and is normalized to percent of the rubric maximum."
          isEmpty={scoreSeries.length === 0}
        >
          <LineChart data={scoreSeries}>
            <CartesianGrid strokeDasharray="3 3" stroke={chartColors.grid} />
            <XAxis dataKey="date" stroke={chartColors.axis} fontSize={12} />
            <YAxis domain={[0, 100]} stroke={chartColors.axis} fontSize={12} />
            <Tooltip />
            <Line
              type="monotone"
              dataKey="scorePercent"
              name="Score %"
              stroke={scoreColor(latestScore)}
              strokeWidth={2}
            />
          </LineChart>
        </ChartCard>

        <ChartCard
          title="Per-criterion averages"
          subtitle="Average score per criterion (% of scale)"
          info="Shows this trainee's average score for each rubric criterion. Lower bars identify the skills that need the most coaching for this trainee."
          isEmpty={data.criterionAverages.length === 0}
        >
          <BarChart data={data.criterionAverages} layout="vertical">
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
              {data.criterionAverages.map(row => (
                <Cell key={row.name} fill={scoreColor(row.avgScorePercent)} />
              ))}
            </Bar>
          </BarChart>
        </ChartCard>
      </div>

      <div className={styles.header}>
        <Title3>Scenario breakdown</Title3>
        {scenarioBreakdown.length === 0 ? (
          <Text>No analyzed practices yet.</Text>
        ) : (
          <Table aria-label="Scenario breakdown" size="small">
            <TableHeader>
              <TableRow>
                <TableHeaderCell>Scenario</TableHeaderCell>
                <TableHeaderCell>Practices</TableHeaderCell>
                <TableHeaderCell>Avg score</TableHeaderCell>
                <TableHeaderCell>Pass rate</TableHeaderCell>
              </TableRow>
            </TableHeader>
            <TableBody>
              {scenarioBreakdown.map(row => (
                <TableRow key={row.scenarioId}>
                  <TableCell>{row.scenarioName}</TableCell>
                  <TableCell>{row.count}</TableCell>
                  <TableCell>{formatPercent(row.avgScorePercent)}</TableCell>
                  <TableCell>{formatPercent(row.passRatePercent)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>

      <div className={styles.header}>
        <Title3>Recent recommendations</Title3>
        {data.recommendations.length === 0 ? (
          <Text>No recommendations recorded.</Text>
        ) : (
          <ul className={styles.recommendations}>
            {data.recommendations.map((recommendation, index) => (
              <li key={index}>
                <Text>{recommendation}</Text>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}
