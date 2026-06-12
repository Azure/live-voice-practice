/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Skeleton,
  SkeletonItem,
  Text,
  Title2,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import type { ReactElement } from 'react'
import { OverviewKpis } from '../../services/statistics'

const useStyles = makeStyles({
  grid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
    gap: tokens.spacingHorizontalL,
    marginBottom: tokens.spacingVerticalL,
  },
  card: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
    backgroundColor: tokens.colorNeutralBackground1,
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    borderRadius: tokens.borderRadiusLarge,
    padding: tokens.spacingVerticalL,
  },
  label: {
    color: tokens.colorNeutralForeground3,
  },
})

interface KpiSpec {
  label: string
  value: string
}

function formatPercent(value: number | null): string {
  return value === null ? '—' : `${value}%`
}

export interface KpiCardsProps {
  kpis: OverviewKpis | null
  loading: boolean
}

/** Renders the headline KPI cards for the statistics overview. */
export function KpiCards({ kpis, loading }: KpiCardsProps): ReactElement {
  const styles = useStyles()

  if (loading || !kpis) {
    return (
      <div className={styles.grid}>
        {Array.from({ length: 5 }).map((_, index) => (
          <div className={styles.card} key={index}>
            <Skeleton>
              <SkeletonItem size={16} />
              <SkeletonItem size={28} />
            </Skeleton>
          </div>
        ))}
      </div>
    )
  }

  const specs: KpiSpec[] = [
    { label: 'Total practices', value: String(kpis.totalPractices) },
    { label: 'Analyzed', value: String(kpis.analyzedPractices) },
    { label: 'Unique trainees', value: String(kpis.uniqueTrainees) },
    { label: 'Average score', value: formatPercent(kpis.averageScorePercent) },
    { label: 'Pass rate', value: formatPercent(kpis.passRatePercent) },
  ]

  return (
    <div className={styles.grid}>
      {specs.map(spec => (
        <div className={styles.card} key={spec.label}>
          <Text size={200} className={styles.label}>
            {spec.label}
          </Text>
          <Title2>{spec.value}</Title2>
        </div>
      ))}
    </div>
  )
}
