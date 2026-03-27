/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
    Badge,
    Button,
    Card,
    CardHeader,
    Dialog,
    DialogActions,
    DialogBody,
    DialogSurface,
    DialogTitle,
    makeStyles,
    ProgressBar,
    Tab,
    TabList,
    TabValue,
    Text,
    tokens,
} from '@fluentui/react-components'
import { useState } from 'react'
import { Assessment } from '../types'

const useStyles = makeStyles({
  dialogBody: {
    padding: tokens.spacingVerticalL,
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalL,
  },
  headerBar: {
    backgroundColor: tokens.colorNeutralBackground2,
    borderRadius: tokens.borderRadiusLarge,
    padding: tokens.spacingVerticalL,
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalS,
  },
  scoreRow: {
    display: 'flex',
    alignItems: 'baseline',
    gap: tokens.spacingHorizontalM,
  },
  scoreValue: {
    fontSize: '48px',
    lineHeight: 1,
    fontWeight: 700,
  },
  tabs: {
    // Remove margins to let the parent container handle spacing
  },
  grid: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    gap: tokens.spacingHorizontalL,
  },
  card: {
    padding: tokens.spacingVerticalL,
    height: 'fit-content',
  },
  tabContent: {
    minHeight: '400px',
  },
  sectionTitle: {
    marginBottom: tokens.spacingVerticalM,
    paddingBottom: tokens.spacingVerticalXS,
    borderBottom: `1px solid ${tokens.colorNeutralStroke2}`,
  },
  metric: {
    marginBottom: tokens.spacingVerticalL,
  },
  metricHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: tokens.spacingVerticalS,
  },
  feedbackCard: {
    padding: tokens.spacingVerticalL,
  },
  feedbackSection: {
    marginBottom: tokens.spacingVerticalXL,
  },
  sectionHeader: {
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalS,
    marginBottom: tokens.spacingVerticalL,
    paddingBottom: tokens.spacingVerticalS,
    borderBottom: `2px solid ${tokens.colorNeutralStroke2}`,
  },
  sectionIcon: {
    fontSize: '24px',
  },
  feedbackGrid: {
    display: 'grid',
    gap: tokens.spacingVerticalM,
  },
  feedbackItem: {
    padding: tokens.spacingVerticalL,
    marginBottom: '0',
    backgroundColor: tokens.colorNeutralBackground1,
    borderRadius: tokens.borderRadiusLarge,
    borderLeft: `4px solid ${tokens.colorBrandBackground}`,
    boxShadow: tokens.shadow4,
    transition: 'all 0.2s ease',
    '&:hover': {
      boxShadow: tokens.shadow8,
      transform: 'translateY(-1px)',
    },
  },
  improvementItem: {
    borderLeftColor: tokens.colorPaletteYellowBackground3,
    backgroundColor: tokens.colorPaletteYellowBackground1,
  },
  strengthItem: {
    borderLeftColor: tokens.colorPaletteGreenBackground3,
    backgroundColor: tokens.colorPaletteGreenBackground1,
  },
  feedbackText: {
    lineHeight: 1.6,
    fontSize: '14px',
  },
  noContent: {
    textAlign: 'center',
    color: tokens.colorNeutralForeground3,
    fontStyle: 'italic',
    padding: tokens.spacingVerticalL,
  },
  wordGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(80px, 1fr))',
    gap: tokens.spacingHorizontalS,
    marginTop: tokens.spacingVerticalM,
  },
})

interface Props {
  open: boolean
  assessment: Assessment | null
  onClose: () => void
}

export function AssessmentPanel({ open, assessment, onClose }: Props) {
  const styles = useStyles()
  const [tab, setTab] = useState<TabValue>('overview')

  if (!assessment) return null

  const ai = assessment.ai_assessment
  const pron = assessment.pronunciation_assessment
  const hasData = !!(ai || pron)

  const isRubricBased = !!(ai?.criteria_scores && Object.keys(ai.criteria_scores).length > 0)

  const getScoreColor = (score: number): 'success' | 'warning' | 'danger' => {
    if (score >= 80) return 'success'
    if (score >= 60) return 'warning'
    return 'danger'
  }

  const getRubricScoreColor = (score: number, max: number = 5): 'success' | 'warning' | 'danger' => {
    const pct = (score / max) * 100
    if (pct >= 70) return 'success'
    if (pct >= 50) return 'warning'
    return 'danger'
  }

  return (
    <Dialog open={open} onOpenChange={(_, data) => !data.open && onClose()}>
      <DialogSurface
        style={{ maxWidth: '1200px', width: '95vw', maxHeight: '90vh' }}
      >
        <DialogTitle>Performance Assessment</DialogTitle>
        <DialogBody className={styles.dialogBody}>
          {!hasData && (
            <div className={styles.noContent}>
              <Text size={400} weight="semibold">
                No assessment data available.
              </Text>
              <Text size={300} block style={{ marginTop: '8px' }}>
                The analysis could not produce results. Please try again or check that the conversation has enough content.
              </Text>
            </div>
          )}

          {/* Overall Score Section */}
          {ai && typeof ai.overall_score === 'number' && (
            <div className={styles.headerBar}>
              <Text size={600} weight="semibold">
                Overall Score
              </Text>
              <div className={styles.scoreRow}>
                <span className={styles.scoreValue}>
                  {isRubricBased ? ai.overall_score.toFixed(1) : ai.overall_score}
                </span>
                {isRubricBased ? (
                  <>
                    <Text size={400} weight="regular">/ 5</Text>
                    <Badge
                      color={getRubricScoreColor(ai.overall_score)}
                      appearance="filled"
                      size="large"
                    >
                      {ai.passed ? '✓ Passed' : '✗ Failed'}
                    </Badge>
                  </>
                ) : (
                  <Badge
                    color={getScoreColor(ai.overall_score)}
                    appearance="filled"
                    size="large"
                  >
                    {ai.overall_score >= 80
                      ? 'Great'
                      : ai.overall_score >= 60
                        ? 'Good'
                        : 'Needs Work'}
                  </Badge>
                )}
              </div>
              <ProgressBar
                value={isRubricBased ? ai.overall_score / 5 : ai.overall_score / 100}
                thickness="large"
              />
            </div>
          )}

          {/* Tabs Section */}
          <TabList
            className={styles.tabs}
            appearance="subtle"
            size="large"
            selectedValue={tab}
            onTabSelect={(_, data) => setTab(data.value)}
          >
            <Tab value="overview">Overview</Tab>
            <Tab value="recommendations">Recommendations</Tab>
            <Tab value="notes">Evaluator Notes</Tab>
          </TabList>

          {/* Content Section */}
          {tab === 'overview' && (
            <div className={styles.grid}>
              {isRubricBased && ai?.criteria_scores && (
                <Card className={styles.card}>
                  <CardHeader
                    header={
                      <Text size={500} weight="semibold">
                        🎯 Rubric Criteria Scores
                      </Text>
                    }
                  />
                  {Object.entries(ai.criteria_scores).map(([criterionId, criterion]) => (
                    <div key={criterionId} className={styles.metric}>
                      <div className={styles.metricHeader}>
                        <Text size={300}>
                          {criterionId.replace(/[-_]/g, ' ').replace(/\b\w/g, c => c.toUpperCase())}
                        </Text>
                        <Badge
                          color={getRubricScoreColor(criterion.score)}
                          appearance="filled"
                        >
                          {criterion.score}/5
                        </Badge>
                      </div>
                      <ProgressBar value={criterion.score / 5} />
                      {criterion.justification && (
                        <Text
                          size={200}
                          style={{ marginTop: '4px', color: tokens.colorNeutralForeground3, display: 'block' }}
                        >
                          {criterion.justification}
                        </Text>
                      )}
                    </div>
                  ))}
                </Card>
              )}

              {!isRubricBased && ai?.speaking_tone_style && ai?.conversation_content && (
                <Card className={styles.card}>
                  <CardHeader
                    header={
                      <Text size={500} weight="semibold">
                        🎯 AI Sales Assessment
                      </Text>
                    }
                  />

                  <div className={styles.sectionTitle}>
                    <Text size={400} weight="semibold">
                      Speaking Tone & Style (
                      {ai.speaking_tone_style.total}/30)
                    </Text>
                  </div>

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Professional Tone</Text>
                      <Badge appearance="tint">
                        {ai.speaking_tone_style.professional_tone}/10
                      </Badge>
                    </div>
                    <ProgressBar
                      value={ai.speaking_tone_style.professional_tone / 10}
                    />
                  </div>

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Active Listening</Text>
                      <Badge appearance="tint">
                        {ai.speaking_tone_style.active_listening}/10
                      </Badge>
                    </div>
                    <ProgressBar
                      value={ai.speaking_tone_style.active_listening / 10}
                    />
                  </div>

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Engagement Quality</Text>
                      <Badge appearance="tint">
                        {ai.speaking_tone_style.engagement_quality}/10
                      </Badge>
                    </div>
                    <ProgressBar
                      value={ai.speaking_tone_style.engagement_quality / 10}
                    />
                  </div>

                  <div className={styles.sectionTitle}>
                    <Text size={400} weight="semibold">
                      Content Quality (
                      {ai.conversation_content.total}/70)
                    </Text>
                  </div>

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Needs Assessment</Text>
                      <Badge appearance="tint">
                        {ai.conversation_content.needs_assessment}/25
                      </Badge>
                    </div>
                    <ProgressBar
                      value={ai.conversation_content.needs_assessment / 25}
                    />
                  </div>

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Value Proposition</Text>
                      <Badge appearance="tint">
                        {ai.conversation_content.value_proposition}/25
                      </Badge>
                    </div>
                    <ProgressBar
                      value={ai.conversation_content.value_proposition / 25}
                    />
                  </div>

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Objection Handling</Text>
                      <Badge appearance="tint">
                        {ai.conversation_content.objection_handling}/20
                      </Badge>
                    </div>
                    <ProgressBar
                      value={ai.conversation_content.objection_handling / 20}
                    />
                  </div>
                </Card>
              )}

              {pron && typeof pron.accuracy_score === 'number' && (
                <Card className={styles.card}>
                  <CardHeader
                    header={
                      <Text size={500} weight="semibold">
                        🗣️ Pronunciation Assessment
                      </Text>
                    }
                  />

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Accuracy</Text>
                      <Badge
                        color={getScoreColor(pron.accuracy_score)}
                        appearance="filled"
                      >
                        {pron.accuracy_score.toFixed(1)}
                      </Badge>
                    </div>
                    <ProgressBar value={pron.accuracy_score / 100} />
                  </div>

                  <div className={styles.metric}>
                    <div className={styles.metricHeader}>
                      <Text size={300}>Fluency</Text>
                      <Badge
                        color={getScoreColor(pron.fluency_score)}
                        appearance="filled"
                      >
                        {pron.fluency_score.toFixed(1)}
                      </Badge>
                    </div>
                    <ProgressBar value={pron.fluency_score / 100} />
                  </div>

                  {pron.words && (
                    <>
                      <div className={styles.sectionTitle}>
                        <Text size={400} weight="semibold">
                          Word-Level Analysis
                        </Text>
                      </div>
                      <div className={styles.wordGrid}>
                        {pron.words.slice(0, 12).map((word, i) => (
                          <Badge
                            key={i}
                            color={getScoreColor(word.accuracy)}
                            appearance="tint"
                            size="small"
                          >
                            {word.word} ({word.accuracy}%)
                          </Badge>
                        ))}
                      </div>
                    </>
                  )}
                </Card>
              )}

              {!isRubricBased && !ai?.speaking_tone_style && !pron && (
                <div className={styles.noContent}>
                  <Text>No detailed scores available for this session.</Text>
                </div>
              )}
            </div>
          )}

          {tab === 'recommendations' && (
            ai ? (
            <Card className={styles.feedbackCard}>
              <CardHeader
                header={
                  <Text size={500} weight="semibold">
                    💡 Improvement Recommendations
                  </Text>
                }
              />

              <div className={styles.feedbackSection}>
                <div className={styles.sectionHeader}>
                  <Text size={500} weight="semibold">
                    Strengths
                  </Text>
                </div>
                {(ai.strengths?.length ?? 0) > 0 ? (
                  <div className={styles.feedbackGrid}>
                    {ai.strengths.map((strength, i) => (
                      <div
                        key={i}
                        className={`${styles.feedbackItem} ${styles.strengthItem}`}
                      >
                        <Text className={styles.feedbackText}>{strength}</Text>
                      </div>
                    ))}
                  </div>
                ) : (
                  <div className={styles.noContent}>
                    <Text>
                      No specific strengths identified in this session.
                    </Text>
                  </div>
                )}
              </div>

              <div className={styles.feedbackSection}>
                <div className={styles.sectionHeader}>
                  <Text size={500} weight="semibold">
                    Areas for Improvement
                  </Text>
                </div>
                {(ai.improvements?.length ?? 0) > 0 ? (
                  <div className={styles.feedbackGrid}>
                    {ai.improvements.map(
                      (improvement, i) => (
                        <div
                          key={i}
                          className={`${styles.feedbackItem} ${styles.improvementItem}`}
                        >
                          <Text className={styles.feedbackText}>
                            {improvement}
                          </Text>
                        </div>
                      )
                    )}
                  </div>
                ) : (
                  <div className={styles.noContent}>
                    <Text>No specific areas for improvement identified.</Text>
                  </div>
                )}
              </div>
            </Card>
            ) : (
              <div className={styles.noContent}>
                <Text>No recommendations available for this session.</Text>
              </div>
            )
          )}

          {tab === 'notes' && (
            <Card className={styles.card}>
              <CardHeader
                header={
                  <Text size={500} weight="semibold">
                    📝 Evaluator Notes
                  </Text>
                }
              />
              <Text size={300} style={{ lineHeight: 1.6 }}>
                {ai?.specific_feedback ||
                  'No evaluator notes available.'}
              </Text>
            </Card>
          )}
        </DialogBody>
        <DialogActions>
          <Button appearance="primary" onClick={onClose}>
            Close
          </Button>
        </DialogActions>
      </DialogSurface>
    </Dialog>
  )
}
