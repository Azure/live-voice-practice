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
import { useCallback, useEffect, useState } from 'react'
import { AssessmentPanel } from '../components/AssessmentPanel'
import { ChatPanel } from '../components/ChatPanel'
import { ConversationDetail } from '../components/ConversationDetail'
import { ConversationList } from '../components/ConversationList'
import { ScenarioList } from '../components/ScenarioList'
import { UserHeader } from '../components/UserHeader'
import { ConnectionStage, VideoPanel } from '../components/VideoPanel'
import { useAudioPlayer } from '../hooks/useAudioPlayer'
import { useAuth } from '../hooks/useAuth'
import { useRealtime } from '../hooks/useRealtime'
import { useRecorder } from '../hooks/useRecorder'
import { useScenarios } from '../hooks/useScenarios'
import { useWebRTC } from '../hooks/useWebRTC'
import { api, AvatarConfig, parseAvatarValue } from '../services/api'
import { Assessment } from '../types'

type AppView = 'setup' | 'practice' | 'conversations' | 'conversationDetail'

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
  brandingBar: {
    position: 'fixed',
    top: 0,
    left: 0,
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalS,
    padding: `${tokens.spacingVerticalS} ${tokens.spacingHorizontalL}`,
    zIndex: 1000,
  },
  brandingLogo: {
    width: '32px',
    height: '32px',
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
  const [currentView, setCurrentView] = useState<AppView>('setup')
  const [previousView, setPreviousView] = useState<AppView>('setup')
  const [showLoading, setShowLoading] = useState(false)
  const [showAssessment, setShowAssessment] = useState(false)
  const [currentAgent, setCurrentAgent] = useState<string | null>(null)
  const [assessment, setAssessment] = useState<Assessment | null>(null)
  const [analysisError, setAnalysisError] = useState<string | null>(null)
  const [connectionStage, setConnectionStage] = useState<ConnectionStage>('creating')
  const [avatarEnabled, setAvatarEnabled] = useState(true)
  const [avatarConfig, setAvatarConfig] = useState<AvatarConfig | null>(null)
  const [selectedConversationId, setSelectedConversationId] = useState<string | null>(null)
  const [showAllPractices, setShowAllPractices] = useState(false)
  const [appName, setAppName] = useState<string>('Live Voice Practice')

  const { authenticated, user, isTrainer } = useAuth()

  const {
    scenarios,
    selectedScenario,
    setSelectedScenario,
    loading,
  } = useScenarios()
  const { playAudio } = useAudioPlayer()
  const activeScenario = scenarios.find(s => s.id === selectedScenario) || null

  // Fetch app name from config
  useEffect(() => {
    api.getConfig().then((cfg: { app_name?: string }) => {
      if (cfg.app_name) setAppName(cfg.app_name)
    }).catch(() => {})
  }, [])

  const navigateToConversations = useCallback(() => {
    setPreviousView(currentView)
    setShowAllPractices(false)
    setCurrentView('conversations')
  }, [currentView])

  const navigateToAllPractices = useCallback(() => {
    setPreviousView(currentView)
    setShowAllPractices(true)
    setCurrentView('conversations')
  }, [currentView])

  const navigateToDetail = useCallback((id: string) => {
    setSelectedConversationId(id)
    setCurrentView('conversationDetail')
  }, [])

  const navigateBack = useCallback(() => {
    if (currentView === 'conversationDetail') {
      setCurrentView('conversations')
      setSelectedConversationId(null)
    } else if (currentView === 'conversations') {
      setCurrentView(previousView)
    }
  }, [currentView, previousView])

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
      setCurrentView('practice')
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

  const handleViewAssessment = useCallback((a: Assessment) => {
    setAssessment(a)
    setShowAssessment(true)
  }, [])

  return (
    <div className={styles.container}>
      <UserHeader userName={user?.name} authenticated={authenticated} role={user?.role} />

      {/* Branding bar - top left on non-setup views */}
      {currentView !== 'setup' && (
        <div className={styles.brandingBar}>
          <img
            src="/images/favicon-32x32.png"
            alt={appName}
            className={styles.brandingLogo}
          />
          <Text size={300} weight="semibold">
            {appName}
          </Text>
        </div>
      )}

      {/* Setup dialog (home screen) */}
      <Dialog
        open={currentView === 'setup'}
        onOpenChange={(_, data) => {
          if (!data.open && currentView === 'setup') {
            // Prevent closing via overlay click on the setup screen
          }
        }}
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
                isAuthenticated={authenticated}
                onNavigateToConversations={navigateToConversations}
                isTrainer={isTrainer}
                onNavigateToAllPractices={navigateToAllPractices}
                appName={appName}
              />
            )}
          </DialogBody>
        </DialogSurface>
      </Dialog>

      {/* Loading overlay */}
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

      {/* Assessment panel overlay */}
      <AssessmentPanel
        open={showAssessment}
        assessment={assessment}
        onClose={() => setShowAssessment(false)}
      />

      {/* Error dialog */}
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

      {/* Practice view */}
      {currentView === 'practice' && (
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
            isAuthenticated={authenticated}
            onNavigateToConversations={navigateToConversations}
            isTrainer={isTrainer}
            onNavigateToAllPractices={navigateToAllPractices}
          />
        </div>
      )}

      {/* Conversation list view */}
      {currentView === 'conversations' && (
        <ConversationList
          onSelectConversation={navigateToDetail}
          onViewAssessment={handleViewAssessment}
          onBack={navigateBack}
          showAll={showAllPractices}
        />
      )}

      {/* Conversation detail view */}
      {currentView === 'conversationDetail' && selectedConversationId && (
        <ConversationDetail
          conversationId={selectedConversationId}
          scenarios={scenarios}
          onBack={navigateBack}
          onShowAssessment={handleViewAssessment}
        />
      )}
    </div>
  )
}
