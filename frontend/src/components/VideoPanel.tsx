/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Button,
  Card,
  ProgressBar,
  Spinner,
  Text,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import React, { useCallback, useEffect, useState } from 'react'

export type ConnectionStage =
  | 'creating'
  | 'connecting'
  | 'configuring'
  | 'rendering'
  | 'ready'

interface StageInfo {
  label: string
  progress: number
}

export interface AvatarConnectionDiagnostics {
  startedAt?: number
  lastUpdatedAt?: number
  message?: string
  voiceSocket?: string
  browserConnection?: string
  networkRelay?: string
  gathering?: string
  candidateTypes?: string[]
  media?: {
    audio?: boolean
    video?: boolean
  }
  warning?: string
}

const STAGES: Record<ConnectionStage, StageInfo> = {
  creating: { label: 'Creating session...', progress: 0.1 },
  connecting: { label: 'Connecting to voice service...', progress: 0.3 },
  configuring: { label: 'Configuring avatar...', progress: 0.5 },
  rendering: {
    label:
      'Getting your avatar ready. Thanks for your patience, this can take around 30 seconds...',
    progress: 0.7,
  },
  ready: { label: 'Ready!', progress: 1.0 },
}

const STAGE_ORDER: ConnectionStage[] = [
  'creating',
  'connecting',
  'configuring',
  'rendering',
  'ready',
]

const useStyles = makeStyles({
  card: {
    width: '400px',
    height: '100%',
    padding: tokens.spacingVerticalM,
  },
  videoContainer: {
    width: '100%',
    aspectRatio: '3 / 4',
    backgroundColor: tokens.colorNeutralBackground1,
    borderRadius: tokens.borderRadiusMedium,
    overflow: 'hidden',
    position: 'relative',
  },
  video: {
    width: '100%',
    height: '100%',
    objectFit: 'cover',
  },
  loadingOverlay: {
    position: 'absolute',
    inset: '0',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: tokens.colorNeutralBackground1,
    gap: tokens.spacingVerticalS,
    zIndex: 1,
    padding: tokens.spacingHorizontalL,
  },
  stageList: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
    marginTop: tokens.spacingVerticalM,
    width: '100%',
    maxWidth: '280px',
  },
  stageRow: {
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalS,
  },
  diagnostics: {
    width: '100%',
    maxWidth: '280px',
    marginTop: tokens.spacingVerticalS,
    padding: `${tokens.spacingVerticalS} ${tokens.spacingHorizontalS}`,
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorNeutralBackground1,
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    boxShadow: tokens.shadow2,
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
  },
  diagnosticsToggle: {
    width: '100%',
    justifyContent: 'space-between',
    padding: 0,
    minWidth: 0,
  },
  diagnosticsHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    gap: tokens.spacingHorizontalS,
  },
  diagnosticsTitle: {
    color: tokens.colorNeutralForeground2,
    textTransform: 'uppercase',
    letterSpacing: '0.04em',
  },
  diagnosticsStatus: {
    color: tokens.colorNeutralForeground1,
  },
  diagnosticsBody: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
  },
  diagnosticsGrid: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    columnGap: tokens.spacingHorizontalM,
    rowGap: tokens.spacingVerticalXXS,
  },
  diagnosticLabel: {
    color: tokens.colorNeutralForeground3,
  },
  diagnosticValue: {
    color: tokens.colorNeutralForeground1,
    fontWeight: tokens.fontWeightSemibold,
  },
  warning: {
    color: tokens.colorPaletteRedForeground1,
  },
  progressBar: {
    width: '100%',
    maxWidth: '280px',
    marginTop: tokens.spacingVerticalS,
  },
})

interface Props {
  videoRef: React.RefObject<HTMLVideoElement | null>
  connectionStage?: ConnectionStage
  diagnostics?: AvatarConnectionDiagnostics
}

function formatElapsed(seconds: number) {
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  const remainingSeconds = seconds % 60
  return `${minutes}m ${remainingSeconds}s`
}

function formatValue(value?: string) {
  return value ? value.split('-').join(' ') : 'waiting'
}

export function VideoPanel({
  videoRef,
  connectionStage = 'creating',
  diagnostics,
}: Props) {
  const styles = useStyles()
  const [videoReady, setVideoReady] = useState<{
    startedAt?: number
    ready: boolean
  }>({ ready: false })
  const [now, setNow] = useState(() => Date.now())
  const [detailsExpanded, setDetailsExpanded] = useState(false)

  const handlePlaying = useCallback(() => {
    setVideoReady({ startedAt: diagnostics?.startedAt, ready: true })
  }, [diagnostics?.startedAt])

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [])

  useEffect(() => {
    const el = videoRef.current
    if (!el) return

    el.addEventListener('playing', handlePlaying)
    return () => el.removeEventListener('playing', handlePlaying)
  }, [videoRef, handlePlaying])

  const currentStageIndex = STAGE_ORDER.indexOf(connectionStage)
  const stageInfo = STAGES[connectionStage]
  const elapsedSeconds = diagnostics?.startedAt
    ? Math.max(0, Math.floor((now - diagnostics.startedAt) / 1000))
    : 0
  const lastUpdateSeconds = diagnostics?.lastUpdatedAt
    ? Math.max(0, Math.floor((now - diagnostics.lastUpdatedAt) / 1000))
    : undefined
  const candidateText = diagnostics?.candidateTypes?.length
    ? diagnostics.candidateTypes.join(', ')
    : 'waiting'
  const mediaText = [
    diagnostics?.media?.video ? 'video' : null,
    diagnostics?.media?.audio ? 'audio' : null,
  ]
    .filter(Boolean)
    .join(' + ')
  const waitWarning =
    !diagnostics?.warning &&
    connectionStage === 'rendering' &&
    elapsedSeconds >= 45
      ? 'Still waiting for avatar media. If this does not finish, retry and share this status.'
      : diagnostics?.warning
  const isVideoReady =
    videoReady.ready && videoReady.startedAt === diagnostics?.startedAt

  return (
    <Card className={styles.card}>
      <div className={styles.videoContainer}>
        {!isVideoReady && (
          <div className={styles.loadingOverlay}>
            <Spinner size="large" />
            <Text size={400} weight="semibold">
              {stageInfo.label}
            </Text>
            <ProgressBar
              className={styles.progressBar}
              value={stageInfo.progress}
              thickness="large"
            />
            <div className={styles.stageList}>
              {STAGE_ORDER.filter(s => s !== 'ready').map((stage, i) => {
                const done = i < currentStageIndex
                const active = i === currentStageIndex
                return (
                  <div key={stage} className={styles.stageRow}>
                    <Text size={200}>{done ? '✓' : active ? '●' : '○'}</Text>
                    <Text
                      size={200}
                      weight={active ? 'semibold' : 'regular'}
                      style={{
                        opacity: done || active ? 1 : 0.5,
                        color: done
                          ? tokens.colorPaletteGreenForeground1
                          : undefined,
                      }}
                    >
                      {STAGES[stage].label}
                    </Text>
                  </div>
                )
              })}
            </div>
            <div className={styles.diagnostics}>
              <Button
                appearance="transparent"
                className={styles.diagnosticsToggle}
                onClick={() => setDetailsExpanded(expanded => !expanded)}
                aria-expanded={detailsExpanded}
              >
                <div className={styles.diagnosticsHeader}>
                  <Text
                    size={100}
                    weight="semibold"
                    className={styles.diagnosticsTitle}
                  >
                    {detailsExpanded ? '▾' : '▸'} Connection details
                  </Text>
                  <Text size={100} className={styles.diagnosticLabel}>
                    {formatElapsed(elapsedSeconds)}
                  </Text>
                </div>
              </Button>
              <Text
                size={200}
                weight="semibold"
                className={styles.diagnosticsStatus}
              >
                {diagnostics?.message ?? stageInfo.label}
              </Text>
              {detailsExpanded && (
                <div className={styles.diagnosticsBody}>
                  <div className={styles.diagnosticsGrid}>
                    <Text size={100} className={styles.diagnosticLabel}>
                      Voice
                    </Text>
                    <Text size={100} className={styles.diagnosticValue}>
                      {formatValue(diagnostics?.voiceSocket)}
                    </Text>
                    <Text size={100} className={styles.diagnosticLabel}>
                      Browser
                    </Text>
                    <Text size={100} className={styles.diagnosticValue}>
                      {formatValue(diagnostics?.browserConnection)}
                    </Text>
                    <Text size={100} className={styles.diagnosticLabel}>
                      Relay
                    </Text>
                    <Text size={100} className={styles.diagnosticValue}>
                      {formatValue(diagnostics?.networkRelay)}
                    </Text>
                    <Text size={100} className={styles.diagnosticLabel}>
                      ICE
                    </Text>
                    <Text size={100} className={styles.diagnosticValue}>
                      {formatValue(diagnostics?.gathering)}
                    </Text>
                    <Text size={100} className={styles.diagnosticLabel}>
                      Candidates
                    </Text>
                    <Text size={100} className={styles.diagnosticValue}>
                      {candidateText}
                    </Text>
                    <Text size={100} className={styles.diagnosticLabel}>
                      Media
                    </Text>
                    <Text size={100} className={styles.diagnosticValue}>
                      {mediaText || 'waiting'}
                    </Text>
                  </div>
                  {lastUpdateSeconds !== undefined && (
                    <Text size={100} className={styles.diagnosticLabel}>
                      Last update {formatElapsed(lastUpdateSeconds)} ago
                    </Text>
                  )}
                </div>
              )}
              {waitWarning && (
                <Text size={200} className={styles.warning}>
                  {waitWarning}
                </Text>
              )}
            </div>
          </div>
        )}
        <video ref={videoRef} className={styles.video} autoPlay playsInline />
      </div>
    </Card>
  )
}
