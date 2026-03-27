/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
    Button,
    Card,
    Spinner,
    Text,
    makeStyles,
    tokens,
} from '@fluentui/react-components'
import {
    ArrowLeft24Regular,
    ChartMultipleRegular,
} from '@fluentui/react-icons'
import { useCallback, useEffect, useState } from 'react'
import { api } from '../services/api'
import { Assessment, ConversationDetailData, Scenario } from '../types'

const useStyles = makeStyles({
  card: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    padding: tokens.spacingVerticalM,
    maxWidth: '800px',
    width: '95%',
  },
  header: {
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalM,
    marginBottom: tokens.spacingVerticalM,
  },
  headerInfo: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
    flex: 1,
  },
  headerDescription: {
    color: tokens.colorNeutralForeground3,
  },
  messages: {
    flex: 1,
    overflowY: 'auto',
    border: `1px solid ${tokens.colorNeutralStroke1}`,
    borderRadius: tokens.borderRadiusMedium,
    padding: tokens.spacingVerticalM,
    marginBottom: tokens.spacingVerticalM,
  },
  message: {
    padding: tokens.spacingVerticalS,
    marginBottom: tokens.spacingVerticalS,
    borderRadius: tokens.borderRadiusMedium,
  },
  userMessage: {
    backgroundColor: tokens.colorBrandBackground2,
    marginLeft: '20%',
  },
  assistantMessage: {
    backgroundColor: tokens.colorNeutralBackground2,
    marginRight: '20%',
  },
  controls: {
    display: 'flex',
    gap: tokens.spacingHorizontalM,
    flexWrap: 'wrap',
  },
  loading: {
    flex: 1,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  },
  error: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: tokens.spacingVerticalM,
    color: tokens.colorNeutralForeground3,
  },
})

interface Props {
  conversationId: string
  scenarios: Scenario[]
  onBack: () => void
  onShowAssessment: (assessment: Assessment) => void
}

export function ConversationDetail({
  conversationId,
  scenarios,
  onBack,
  onShowAssessment,
}: Props) {
  const styles = useStyles()
  const [conversation, setConversation] = useState<ConversationDetailData | null>(null)
  const [loading, setLoading] = useState(true)
  const [analyzing, setAnalyzing] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    setLoading(true)
    setError(null)
    api
      .getConversation(conversationId)
      .then(data => setConversation(data))
      .catch(() => setError('Failed to load conversation.'))
      .finally(() => setLoading(false))
  }, [conversationId])

  const scenario = scenarios.find(s => s.id === conversation?.scenario_id) || null

  const hasAssessment = !!conversation?.assessment?.ai_assessment

  const handleAnalyze = useCallback(async () => {
    if (!conversation) return
    setAnalyzing(true)
    try {
      const msgs = conversation.messages || []
      const transcript = msgs.map(m => `${m.role}: ${m.content}`).join('\n')
      const result = await api.analyzeConversation(
        conversation.scenario_id,
        transcript,
        [],
        msgs,
        conversation.id
      )
      setConversation(prev =>
        prev ? { ...prev, assessment: result, status: 'analyzed' } : prev
      )
      onShowAssessment(result)
    } catch {
      setError('Performance analysis failed. Please try again.')
    } finally {
      setAnalyzing(false)
    }
  }, [conversation, onShowAssessment])

  if (loading) {
    return (
      <Card className={styles.card}>
        <div className={styles.loading}>
          <Spinner label="Loading conversation..." />
        </div>
      </Card>
    )
  }

  if (error && !conversation) {
    return (
      <Card className={styles.card}>
        <div className={styles.error}>
          <Text size={400}>{error}</Text>
          <Button appearance="secondary" onClick={onBack}>
            Go Back
          </Button>
        </div>
      </Card>
    )
  }

  if (!conversation) return null

  const messages = conversation.messages || []
  const dateStr = new Date(conversation.created_at).toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })

  return (
    <Card className={styles.card}>
      <div className={styles.header}>
        <Button
          appearance="subtle"
          icon={<ArrowLeft24Regular />}
          onClick={onBack}
        />
        <div className={styles.headerInfo}>
          <Text size={500} weight="semibold">
            {scenario?.name || conversation.scenario_id}
          </Text>
          <Text size={200} className={styles.headerDescription}>
            {dateStr}
            {conversation.metadata?.user_name
              ? ` · ${conversation.metadata.user_name}`
              : ''}
          </Text>
        </div>
      </div>

      <div className={styles.messages}>
        {messages.length === 0 ? (
          <Text size={300} style={{ color: tokens.colorNeutralForeground3 }}>
            No messages in this conversation.
          </Text>
        ) : (
          messages.map((msg, idx) => (
            <div
              key={idx}
              className={`${styles.message} ${
                msg.role === 'user'
                  ? styles.userMessage
                  : styles.assistantMessage
              }`}
            >
              <Text size={300}>{msg.content}</Text>
            </div>
          ))
        )}
      </div>

      <div className={styles.controls}>
        <Button
          appearance="primary"
          icon={<ChartMultipleRegular />}
          onClick={handleAnalyze}
          disabled={analyzing || messages.length === 0}
        >
          {analyzing
            ? 'Analyzing...'
            : hasAssessment
              ? 'Reanalyze Performance'
              : 'Analyze Performance'}
        </Button>

        {hasAssessment && conversation.assessment && (
          <Button
            appearance="secondary"
            icon={<ChartMultipleRegular />}
            onClick={() => onShowAssessment(conversation.assessment!)}
          >
            View Assessment
          </Button>
        )}
      </div>
    </Card>
  )
}
