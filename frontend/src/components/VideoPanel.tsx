/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
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

const STAGES: Record<ConnectionStage, StageInfo> = {
  creating: { label: 'Creating session...', progress: 0.1 },
  connecting: { label: 'Connecting to voice service...', progress: 0.3 },
  configuring: { label: 'Configuring avatar...', progress: 0.5 },
  rendering: {
    label: 'Getting your avatar ready. Thanks for your patience, this can take around 30 seconds...',
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
  progressBar: {
    width: '100%',
    maxWidth: '280px',
    marginTop: tokens.spacingVerticalS,
  },
})

interface Props {
  videoRef: React.RefObject<HTMLVideoElement | null>
  connectionStage?: ConnectionStage
}

export function VideoPanel({ videoRef, connectionStage = 'creating' }: Props) {
  const styles = useStyles()
  const [videoReady, setVideoReady] = useState(false)

  const handlePlaying = useCallback(() => {
    setVideoReady(true)
  }, [])

  useEffect(() => {
    const el = videoRef.current
    if (!el) return

    el.addEventListener('playing', handlePlaying)
    return () => el.removeEventListener('playing', handlePlaying)
  }, [videoRef, handlePlaying])

  const currentStageIndex = STAGE_ORDER.indexOf(connectionStage)
  const stageInfo = STAGES[connectionStage]

  return (
    <Card className={styles.card}>
      <div className={styles.videoContainer}>
        {!videoReady && (
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
                        color: done ? tokens.colorPaletteGreenForeground1 : undefined,
                      }}
                    >
                      {STAGES[stage].label}
                    </Text>
                  </div>
                )
              })}
            </div>
          </div>
        )}
        <video ref={videoRef} className={styles.video} autoPlay playsInline />
      </div>
    </Card>
  )
}
