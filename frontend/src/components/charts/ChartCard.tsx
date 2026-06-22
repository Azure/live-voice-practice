/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  InfoLabel,
  Spinner,
  Text,
  Title3,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import type { ReactElement } from 'react'
import { ResponsiveContainer } from 'recharts'

const useStyles = makeStyles({
  card: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalS,
    backgroundColor: tokens.colorNeutralBackground1,
    borderRadius: tokens.borderRadiusLarge,
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    padding: tokens.spacingVerticalL,
    boxSizing: 'border-box',
  },
  header: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXXS,
  },
  titleRow: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: tokens.spacingHorizontalS,
  },
  body: {
    width: '100%',
  },
  centered: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  },
})

export interface ChartCardProps {
  title: string
  subtitle?: string
  loading?: boolean
  isEmpty?: boolean
  emptyLabel?: string
  height?: number
  info?: string
  /** A single Recharts chart element (e.g. <LineChart>…</LineChart>). */
  children: ReactElement
}

/**
 * The single charting primitive reused across the admin Statistics tab. It
 * renders a titled Fluent card and hosts the provided Recharts chart inside a
 * ResponsiveContainer, with built-in loading and empty states so callers never
 * re-implement them.
 */
export function ChartCard({
  title,
  subtitle,
  loading = false,
  isEmpty = false,
  emptyLabel = 'No data for the selected filters.',
  height = 280,
  info,
  children,
}: ChartCardProps): ReactElement {
  const styles = useStyles()

  return (
    <div className={styles.card}>
      <div className={styles.header}>
        <div className={styles.titleRow}>
          <Title3>{title}</Title3>
          {info && <InfoLabel info={info} size="medium" />}
        </div>
        {subtitle && <Text size={200}>{subtitle}</Text>}
      </div>
      <div className={styles.body} style={{ height }}>
        {loading ? (
          <div className={styles.centered} style={{ height }}>
            <Spinner label="Loading…" />
          </div>
        ) : isEmpty ? (
          <div className={styles.centered} style={{ height }}>
            <Text>{emptyLabel}</Text>
          </div>
        ) : (
          <ResponsiveContainer width="100%" height={height}>
            {children}
          </ResponsiveContainer>
        )}
      </div>
    </div>
  )
}
