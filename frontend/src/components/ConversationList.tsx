/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
    Button,
    Card,
    Spinner,
    Table,
    TableBody,
    TableCell,
    TableHeader,
    TableHeaderCell,
    TableRow,
    Text,
    makeStyles,
    tokens,
} from '@fluentui/react-components'
import {
    ArrowLeft24Regular,
    ArrowSortDownRegular,
    ArrowSortUpRegular,
    ChartMultipleRegular,
    DeleteRegular,
} from '@fluentui/react-icons'
import { useConversations } from '../hooks/useConversations'
import { api } from '../services/api'
import { Assessment, ConversationSummary } from '../types'

const useStyles = makeStyles({
  card: {
    width: '95%',
    maxWidth: '1200px',
    padding: tokens.spacingVerticalL,
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalM,
  },
  header: {
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalM,
  },
  tableContainer: {
    flex: 1,
    overflowY: 'auto',
  },
  headerCell: {
    cursor: 'pointer',
    userSelect: 'none',
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalXS,
  },
  row: {
    cursor: 'pointer',
    '&:hover': {
      backgroundColor: tokens.colorNeutralBackground1Hover,
    },
  },
  assessmentIcon: {
    cursor: 'pointer',
    color: tokens.colorBrandForeground1,
    '&:hover': {
      color: tokens.colorBrandForeground2,
    },
  },
  deleteIcon: {
    color: tokens.colorNeutralForeground3,
    '&:hover': {
      color: tokens.colorPaletteRedForeground1,
    },
  },
  pagination: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: tokens.spacingHorizontalM,
    paddingTop: tokens.spacingVerticalM,
  },
  emptyState: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    padding: tokens.spacingVerticalXXL,
    color: tokens.colorNeutralForeground3,
  },
  loading: {
    display: 'flex',
    justifyContent: 'center',
    padding: tokens.spacingVerticalXXL,
  },
})

interface Props {
  onSelectConversation: (id: string) => void
  onViewAssessment: (assessment: Assessment) => void
  onBack: () => void
  showAll?: boolean
}

type SortableColumn = 'created_at' | 'updated_at' | 'scenario_id'

function formatDate(dateStr: string): string {
  const date = new Date(dateStr)
  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function ConversationList({
  onSelectConversation,
  onViewAssessment,
  onBack,
  showAll,
}: Props) {
  const styles = useStyles()
  const {
    conversations,
    loading,
    totalPages,
    currentPage,
    sortBy,
    sortOrder,
    setPage,
    setSort,
    refresh,
  } = useConversations(showAll)

  const handleSort = (column: SortableColumn) => {
    if (sortBy === column) {
      setSort(column, sortOrder === 'asc' ? 'desc' : 'asc')
    } else {
      setSort(column, column === 'created_at' ? 'desc' : 'asc')
    }
  }

  const SortIcon = ({ column }: { column: SortableColumn }) => {
    if (sortBy !== column) return null
    return sortOrder === 'asc' ? (
      <ArrowSortUpRegular fontSize={12} />
    ) : (
      <ArrowSortDownRegular fontSize={12} />
    )
  }

  const handleAssessmentClick = (
    e: React.MouseEvent,
    conv: ConversationSummary
  ) => {
    e.stopPropagation()
    if (conv.assessment) {
      onViewAssessment(conv.assessment)
    }
  }

  const handleDelete = async (e: React.MouseEvent, convId: string) => {
    e.stopPropagation()
    try {
      await api.deleteConversation(convId)
      refresh()
    } catch (err) {
      console.error('Failed to delete conversation:', err)
    }
  }

  return (
    <Card className={styles.card}>
      <div className={styles.header}>
        <Button
          appearance="subtle"
          icon={<ArrowLeft24Regular />}
          onClick={onBack}
        />
        <Text size={600} weight="semibold">
          {showAll ? 'All Practices' : 'My Practices'}
        </Text>
      </div>

      {loading ? (
        <div className={styles.loading}>
          <Spinner label="Loading practices..." />
        </div>
      ) : conversations.length === 0 ? (
        <div className={styles.emptyState}>
          <Text size={400} weight="semibold">
            No practices yet
          </Text>
          <Text size={300}>
            Start a new training to see your history here.
          </Text>
        </div>
      ) : (
        <>
          <div className={styles.tableContainer}>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHeaderCell onClick={() => handleSort('created_at')}>
                    <div className={styles.headerCell}>
                      Date <SortIcon column="created_at" />
                    </div>
                  </TableHeaderCell>
                  <TableHeaderCell onClick={() => handleSort('scenario_id')}>
                    <div className={styles.headerCell}>
                      Scenario <SortIcon column="scenario_id" />
                    </div>
                  </TableHeaderCell>
                  <TableHeaderCell>
                    <div className={styles.headerCell}>User</div>
                  </TableHeaderCell>
                  <TableHeaderCell>
                    <div className={styles.headerCell}>Assessment</div>
                  </TableHeaderCell>
                  <TableHeaderCell />
                </TableRow>
              </TableHeader>
              <TableBody>
                {conversations.map(conv => (
                  <TableRow
                    key={conv.id}
                    className={styles.row}
                    onClick={() => onSelectConversation(conv.id)}
                  >
                    <TableCell>
                      <Text size={300}>{formatDate(conv.created_at)}</Text>
                    </TableCell>
                    <TableCell>
                      <Text size={300}>
                        {conv.scenario_name || conv.scenario_id}
                      </Text>
                    </TableCell>
                    <TableCell>
                      <Text size={300}>
                        {conv.metadata?.user_name || '—'}
                      </Text>
                    </TableCell>
                    <TableCell>
                      {conv.assessment?.ai_assessment ? (
                        <Button
                          appearance="subtle"
                          icon={<ChartMultipleRegular />}
                          size="small"
                          className={styles.assessmentIcon}
                          onClick={e => handleAssessmentClick(e, conv)}
                          title="View assessment"
                        />
                      ) : null}
                    </TableCell>
                    <TableCell>
                      <Button
                        appearance="subtle"
                        icon={<DeleteRegular />}
                        size="small"
                        className={styles.deleteIcon}
                        onClick={e => handleDelete(e, conv.id)}
                        title="Delete conversation"
                      />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>

          <div className={styles.pagination}>
            <Button
              appearance="subtle"
              disabled={currentPage <= 1}
              onClick={() => setPage(currentPage - 1)}
            >
              Previous
            </Button>
            <Text size={300}>
              Page {currentPage} of {totalPages}
            </Text>
            <Button
              appearance="subtle"
              disabled={currentPage >= totalPages}
              onClick={() => setPage(currentPage + 1)}
            >
              Next
            </Button>
          </div>
        </>
      )}
    </Card>
  )
}
