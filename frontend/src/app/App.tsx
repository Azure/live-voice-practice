/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
    Button,
    Dialog,
    DialogBody,
    DialogSurface,
    makeStyles,
    Spinner,
    Text,
    tokens,
} from '@fluentui/react-components'
import { useCallback, useState } from 'react'
import { AssessmentPanel } from '../components/AssessmentPanel'
import { ChatPanel } from '../components/ChatPanel'
import { ScenarioList } from '../components/ScenarioList'
import { ConnectionStage, VideoPanel } from '../components/VideoPanel'
import { useAudioPlayer } from '../hooks/useAudioPlayer'
import { useRealtime } from '../hooks/useRealtime'
import { useRecorder } from '../hooks/useRecorder'
import { useScenarios } from '../hooks/useScenarios'
import { useWebRTC } from '../hooks/useWebRTC'
import { api, AvatarConfig, parseAvatarValue } from '../services/api'
import { Assessment } from '../types'

const useStyles = makeStyles({
  container: {
    width: '100%',
    height: '100vh',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: tokens.colorNeutralBackground3,
    padding: tokens.spacingVerticalL,
  },
  mainLayout: {
    width: '95%',
    maxWidth: '1400px',
    height: '90vh',
    display: 'flex',
    gap: tokens.spacingHorizontalL,
  },
  setupDialog: {
    maxWidth: '600px',
    width: '90vw',
  },
  loadingContent: {
    gridColumn: '1 / -1',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    textAlign: 'center',
    width: '100%',
  },
})

export default function App() {
  const styles = useStyles()
  const [showSetup, setShowSetup] = useState(true)
  const [showLoading, setShowLoading] = useState(false)
  const [showAssessment, setShowAssessment] = useState(false)
  const [currentAgent, setCurrentAgent] = useState<string | null>(null)
  const [assessment, setAssessment] = useState<Assessment | null>(null)
  const [analysisError, setAnalysisError] = useState<string | null>(null)
  const [connectionStage, setConnectionStage] = useState<ConnectionStage>('creating')
  const [avatarEnabled, setAvatarEnabled] = useState(true)
  const [avatarConfig, setAvatarConfig] = useState<AvatarConfig | null>(null)

  const {
    scenarios,
    selectedScenario,
    setSelectedScenario,
    loading,
  } = useScenarios()
  const { playAudio } = useAudioPlayer()
  const activeScenario = scenarios.find(s => s.id === selectedScenario) || null

  const handleWebRTCMessage = useCallback((msg: any) => {
    if (!avatarEnabled) return

    if (msg.type === 'proxy.connected') {
      setConnectionStage('connecting')
    } else if (msg.type === 'session.created') {
      setConnectionStage('configuring')
    } else if (msg.type === 'session.updated') {
      setConnectionStage('rendering')
      const session = msg.session
      const servers =
        session?.avatar?.ice_servers ||
        session?.rtc?.ice_servers ||
        session?.ice_servers
      const username =
        session?.avatar?.username ||
        session?.avatar?.ice_username ||
        session?.rtc?.ice_username ||
        session?.ice_username
      const credential =
        session?.avatar?.credential ||
        session?.avatar?.ice_credential ||
        session?.rtc?.ice_credential ||
        session?.ice_credential

      if (servers) {
        setupWebRTC(servers, username, credential)
      }
    } else if (
      (msg.server_sdp || msg.sdp || msg.answer) &&
      msg.type !== 'session.update'
    ) {
      handleAnswer(msg)
    }
  }, [avatarEnabled])

  const { connected, messages, send, clearMessages, getRecordings, getConversationId } =
    useRealtime({
      agentId: currentAgent,
      scenarioId: selectedScenario,
      onMessage: handleWebRTCMessage,
      onAudioDelta: playAudio,
    })

  const sendOffer = useCallback(
    (sdp: string) => {
      send({ type: 'session.avatar.connect', client_sdp: sdp })
    },
    [send]
  )

  const { setupWebRTC, handleAnswer, videoRef } = useWebRTC(sendOffer)

  const sendAudioChunk = useCallback(
    (base64: string) => {
      send({ type: 'input_audio_buffer.append', audio: base64 })
    },
    [send]
  )

  const { recording, toggleRecording, getAudioRecording } =
    useRecorder(sendAudioChunk)

  const handleStart = async (avatarValue: string) => {
    if (!selectedScenario) return

    const parsedAvatar = parseAvatarValue(avatarValue)
    const isAudioOnly = parsedAvatar === null
    setAvatarConfig(parsedAvatar)
    setAvatarEnabled(!isAudioOnly)

    setConnectionStage('creating')
    try {
      const { agent_id } = await api.createAgent(selectedScenario, parsedAvatar)

      if (!isAudioOnly) {
        setConnectionStage('connecting')
      }
      setCurrentAgent(agent_id)
      setShowSetup(false)
    } catch (error) {
      console.error('Failed to create agent:', error)
    }
  }

  const handleAnalyze = async () => {
    if (!selectedScenario) return

    const recordings = getRecordings()
    const audioData = getAudioRecording()

    if (!recordings.conversation.length) return

    setShowLoading(true)
    setAnalysisError(null)

    try {
      const transcript = recordings.conversation
        .map((m: any) => `${m.role}: ${m.content}`)
        .join('\n')

      const result = await api.analyzeConversation(
        selectedScenario,
        transcript,
        [...audioData, ...recordings.audio],
        recordings.conversation,
        getConversationId()
      )

      setAssessment(result)
      setShowAssessment(true)
    } catch (error) {
      console.error('Analysis failed:', error)
      setAnalysisError('Performance analysis failed. Please try again.')
    } finally {
      setShowLoading(false)
    }
  }

  return (
    <div className={styles.container}>
      <Dialog
        open={showSetup}
        onOpenChange={(_, data) => setShowSetup(data.open)}
      >
        <DialogSurface className={styles.setupDialog}>
          <DialogBody>
            {loading ? (
              <Spinner label="Loading scenarios..." />
            ) : (
              <ScenarioList
                scenarios={scenarios}
                selectedScenario={selectedScenario}
                onSelect={setSelectedScenario}
                onStart={handleStart}
              />
            )}
          </DialogBody>
        </DialogSurface>
      </Dialog>

      <Dialog open={showLoading}>
        <DialogSurface>
          <DialogBody>
            <div className={styles.loadingContent}>
              <Spinner size="large" />
              <Text
                size={400}
                weight="semibold"
                block
                style={{ marginTop: tokens.spacingVerticalL }}
              >
                Analyzing Performance...
              </Text>
              <Text
                size={200}
                block
                style={{ marginTop: tokens.spacingVerticalS }}
              >
                This may take a few moments
              </Text>
            </div>
          </DialogBody>
        </DialogSurface>
      </Dialog>

      <AssessmentPanel
        open={showAssessment}
        assessment={assessment}
        onClose={() => setShowAssessment(false)}
      />

      <Dialog open={!!analysisError} onOpenChange={() => setAnalysisError(null)}>
        <DialogSurface>
          <DialogBody>
            <Text size={400} weight="semibold" block>
              Analysis Error
            </Text>
            <Text size={300} block style={{ marginTop: tokens.spacingVerticalM }}>
              {analysisError}
            </Text>
            <div style={{ marginTop: tokens.spacingVerticalL, display: 'flex', justifyContent: 'flex-end' }}>
              <Button appearance="primary" onClick={() => setAnalysisError(null)}>
                OK
              </Button>
            </div>
          </DialogBody>
        </DialogSurface>
      </Dialog>

      {!showSetup && (
        <div className={styles.mainLayout}>
          {avatarEnabled && (
            <VideoPanel videoRef={videoRef} connectionStage={connectionStage} />
          )}
          <ChatPanel
            messages={messages}
            recording={recording}
            connected={connected}
            canAnalyze={messages.length > 0}
            onToggleRecording={toggleRecording}
            onClear={clearMessages}
            onAnalyze={handleAnalyze}
            scenario={activeScenario}
            avatarEnabled={avatarEnabled}
            onToggleAvatar={() => setAvatarEnabled(prev => !prev)}
            hasAvatarConfig={avatarConfig !== null}
          />
        </div>
      )}
    </div>
  )
}
