/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Button,
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
  Title3,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import { useState } from 'react'
import type { ReactElement } from 'react'
import { useNavigate } from 'react-router-dom'
import { useStatisticsTrainees } from '../../hooks/useStatisticsTrainees'
import {
  StatisticsFilters,
  TraineeRow,
  statisticsApi,
} from '../../services/statistics'

const PAGE_SIZE = 25

const useStyles = makeStyles({
  root: {
    marginTop: tokens.spacingVerticalXL,
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalM,
  },
  header: {
    display: 'flex',
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: tokens.spacingHorizontalM,
  },
  headerText: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXXS,
  },
  row: {
    cursor: 'pointer',
  },
  pager: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: tokens.spacingHorizontalM,
  },
  trendUp: { color: tokens.colorPaletteGreenForeground1 },
  trendDown: { color: tokens.colorPaletteRedForeground1 },
})

type SortKey =
  | 'displayName'
  | 'practices'
  | 'lastPracticeAt'
  | 'avgScorePercent'
  | 'passRatePercent'

const COLUMNS: { key: SortKey; label: string }[] = [
  { key: 'displayName', label: 'Trainee' },
  { key: 'practices', label: 'Practices' },
  { key: 'lastPracticeAt', label: 'Last practice' },
  { key: 'avgScorePercent', label: 'Avg score' },
  { key: 'passRatePercent', label: 'Pass rate' },
]

function formatPercent(value: number | null): string {
  return value === null ? '—' : `${value}%`
}

function formatDate(value: string | null): string {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleDateString()
}

function TrendCell({ row }: { row: TraineeRow }): ReactElement {
  const styles = useStyles()
  if (row.trendDelta === null) return <Text>—</Text>
  const className =
    row.trendDelta > 0
      ? styles.trendUp
      : row.trendDelta < 0
        ? styles.trendDown
        : undefined
  const arrow = row.trendDelta > 0 ? '▲' : row.trendDelta < 0 ? '▼' : '→'
  return (
    <Text className={className}>
      {arrow} {Math.abs(row.trendDelta)}%
    </Text>
  )
}

export interface TraineesTableProps {
  filters: StatisticsFilters
}

/**
 * Sortable, paginated table of per-trainee aggregates. Rows link to the
 * trainee detail view. Identity is whatever the backend returns (real name or
 * anonymized label), so this component stays anonymization-agnostic.
 */
export function TraineesTable({ filters }: TraineesTableProps): ReactElement {
  const styles = useStyles()
  const navigate = useNavigate()
  const [sortBy, setSortBy] = useState<SortKey>('lastPracticeAt')
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc')
  const [offset, setOffset] = useState(0)

  const { data, loading, error } = useStatisticsTrainees({
    ...filters,
    sortBy,
    sortOrder,
    limit: PAGE_SIZE,
    offset,
  })

  const onSort = (key: SortKey): void => {
    if (key === sortBy) {
      setSortOrder(prev => (prev === 'asc' ? 'desc' : 'asc'))
    } else {
      setSortBy(key)
      setSortOrder('desc')
    }
    setOffset(0)
  }

  const total = data?.total ?? 0
  const items = data?.items ?? []
  const pageEnd = offset + items.length

  return (
    <div className={styles.root}>
      <div className={styles.header}>
        <div className={styles.headerText}>
          <Title3>Trainees</Title3>
          <Text size={200}>
            Per-trainee progress across the selected filters.
          </Text>
        </div>
        <Button
          as="a"
          size="small"
          href={statisticsApi.buildExportUrl(filters)}
          download
        >
          Export CSV
        </Button>
      </div>

      {error && (
        <MessageBar intent="error">
          <MessageBarBody>{error}</MessageBarBody>
        </MessageBar>
      )}

      {loading ? (
        <Spinner label="Loading trainees…" />
      ) : items.length === 0 ? (
        <Text>No trainees match the selected filters.</Text>
      ) : (
        <>
          <Table aria-label="Trainees" size="small">
            <TableHeader>
              <TableRow>
                {COLUMNS.map(column => (
                  <TableHeaderCell
                    key={column.key}
                    onClick={() => onSort(column.key)}
                    sortDirection={
                      sortBy === column.key
                        ? sortOrder === 'asc'
                          ? 'ascending'
                          : 'descending'
                        : undefined
                    }
                  >
                    {column.label}
                  </TableHeaderCell>
                ))}
                <TableHeaderCell>Trend</TableHeaderCell>
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.map(row => (
                <TableRow
                  key={row.userId}
                  className={styles.row}
                  onClick={() =>
                    navigate(
                      `/admin/statistics/trainees/${encodeURIComponent(row.userId)}`
                    )
                  }
                >
                  <TableCell>{row.displayName}</TableCell>
                  <TableCell>{row.practices}</TableCell>
                  <TableCell>{formatDate(row.lastPracticeAt)}</TableCell>
                  <TableCell>{formatPercent(row.avgScorePercent)}</TableCell>
                  <TableCell>{formatPercent(row.passRatePercent)}</TableCell>
                  <TableCell>
                    <TrendCell row={row} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>

          <div className={styles.pager}>
            <Text size={200}>
              {offset + 1}–{pageEnd} of {total}
            </Text>
            <Button
              size="small"
              disabled={offset === 0}
              onClick={() => setOffset(Math.max(0, offset - PAGE_SIZE))}
            >
              Previous
            </Button>
            <Button
              size="small"
              disabled={pageEnd >= total}
              onClick={() => setOffset(offset + PAGE_SIZE)}
            >
              Next
            </Button>
          </div>
        </>
      )}
    </div>
  )
}
