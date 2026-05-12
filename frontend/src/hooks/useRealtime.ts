/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../services/api'
import { Message } from '../types'

interface RealtimeOptions {
  agentId?: string | null
  scenarioId?: string | null
  onMessage?: (msg: any) => void
  onAudioDelta?: (delta: string) => void
  onTranscript?: (role: 'user' | 'assistant', text: string) => void
  onConnectionStatus?: (status: {
    message: string
    voiceSocket?: string
    warning?: string
  }) => void
}

const SAVE_DEBOUNCE_MS = 5000
const RECONNECT_MAX_ATTEMPTS = 8
const RECONNECT_BASE_DELAY_MS = 1000
const RECONNECT_MAX_DELAY_MS = 30000
const KEEPALIVE_INTERVAL_MS = 25000

export function useRealtime(options: RealtimeOptions) {
  const [connected, setConnected] = useState(false)
  const [messages, setMessages] = useState<Message[]>([])
  const wsRef = useRef<WebSocket | null>(null)
  const audioRecording = useRef<any[]>([])
  const conversationRecording = useRef<any[]>([])
  const conversationIdRef = useRef<string | null>(null)
  const saveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pendingSaveRef = useRef(false)
  const manualCloseRef = useRef(false)
  const reconnectAttemptsRef = useRef(0)
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const keepAliveTimerRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const connectRef = useRef<(() => Promise<void>) | null>(null)

  const stopKeepAlive = useCallback(() => {
    if (keepAliveTimerRef.current) {
      clearInterval(keepAliveTimerRef.current)
      keepAliveTimerRef.current = null
    }
  }, [])

  const startKeepAlive = useCallback(() => {
    stopKeepAlive()
    keepAliveTimerRef.current = setInterval(() => {
      if (wsRef.current?.readyState === WebSocket.OPEN) {
        try {
          wsRef.current.send(JSON.stringify({ type: 'client.ping' }))
        } catch (err) {
          console.warn('Keep-alive ping failed:', err)
        }
      }
    }, KEEPALIVE_INTERVAL_MS)
  }, [stopKeepAlive])
  const scheduleSave = useCallback(() => {
    if (saveTimerRef.current) clearTimeout(saveTimerRef.current)
    pendingSaveRef.current = true
    saveTimerRef.current = setTimeout(() => {
      if (!conversationIdRef.current || !pendingSaveRef.current) return
      const msgs = conversationRecording.current
      const transcript = msgs
        .map((m: any) => `${m.role}: ${m.content}`)
        .join('\n')
      api
        .updateConversationMessages(conversationIdRef.current, msgs, transcript)
        .catch(err =>
          console.warn('Failed to save conversation messages:', err)
        )
      pendingSaveRef.current = false
    }, SAVE_DEBOUNCE_MS)
  }, [])

  const ensureConversationCreated = useCallback(async () => {
    if (conversationIdRef.current || !options.scenarioId) {
      return conversationIdRef.current
    }
    try {
      const result = await api.createConversation(options.scenarioId)
      conversationIdRef.current = result.conversation_id
      return conversationIdRef.current
    } catch (err) {
      console.warn('Failed to create conversation record:', err)
      return null
    }
  }, [options.scenarioId])

  const connect = useCallback(async () => {
    if (reconnectTimerRef.current) {
      clearTimeout(reconnectTimerRef.current)
      reconnectTimerRef.current = null
    }

    if (!options.agentId) {
      manualCloseRef.current = true
      if (wsRef.current) {
        wsRef.current.close()
        wsRef.current = null
      }
      setConnected(false)
      return
    }

    manualCloseRef.current = false

    const isReconnect = reconnectAttemptsRef.current > 0
    options.onConnectionStatus?.({
      message: isReconnect
        ? `Reconnecting voice connection (attempt ${reconnectAttemptsRef.current})`
        : 'Loading voice connection settings',
      voiceSocket: 'starting',
    })
    const config = await fetch('/api/config').then(r => r.json())
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
    const ws = new WebSocket(
      `${protocol}//${location.host}${config.ws_endpoint}`
    )
    options.onConnectionStatus?.({
      message: 'Opening voice connection',
      voiceSocket: 'connecting',
    })

    ws.onopen = () => {
      const wasReconnect = reconnectAttemptsRef.current > 0
      reconnectAttemptsRef.current = 0
      setConnected(true)
      options.onConnectionStatus?.({
        message: wasReconnect
          ? 'Voice connection restored'
          : 'Voice connection is open',
        voiceSocket: 'open',
      })
      ws.send(
        JSON.stringify({
          type: 'session.update',
          session: { agent_id: options.agentId },
        })
      )
      startKeepAlive()
    }

    ws.onmessage = event => {
      const msg = JSON.parse(event.data)
      options.onMessage?.(msg)

      switch (msg.type) {
        case 'response.audio.delta':
          if (msg.delta) {
            options.onAudioDelta?.(msg.delta)
            audioRecording.current.push({
              type: 'assistant',
              data: msg.delta,
              timestamp: new Date().toISOString(),
            })
          }
          break
        case 'conversation.item.input_audio_transcription.completed':
          if (msg.transcript) {
            const message: Message = {
              id: crypto.randomUUID(),
              role: 'user',
              content: msg.transcript,
              timestamp: new Date(),
            }
            setMessages(prev => [...prev, message])
            conversationRecording.current.push({
              role: 'user',
              content: msg.transcript,
            })
            options.onTranscript?.('user', msg.transcript)
            ensureConversationCreated().then(scheduleSave)
          }
          break
        case 'response.audio_transcript.done':
          if (msg.transcript) {
            const message: Message = {
              id: crypto.randomUUID(),
              role: 'assistant',
              content: msg.transcript,
              timestamp: new Date(),
            }
            setMessages(prev => [...prev, message])
            conversationRecording.current.push({
              role: 'assistant',
              content: msg.transcript,
            })
            options.onTranscript?.('assistant', msg.transcript)
            ensureConversationCreated().then(scheduleSave)
          }
          break
      }
    }

    ws.onerror = () => {
      options.onConnectionStatus?.({
        message: 'Voice connection error',
        voiceSocket: 'error',
        warning: 'The browser could not keep the voice connection open.',
      })
    }

    ws.onclose = () => {
      setConnected(false)
      stopKeepAlive()

      if (manualCloseRef.current || !options.agentId) {
        options.onConnectionStatus?.({
          message: 'Voice connection closed',
          voiceSocket: 'closed',
        })
        return
      }

      if (reconnectAttemptsRef.current >= RECONNECT_MAX_ATTEMPTS) {
        options.onConnectionStatus?.({
          message: 'Voice connection lost',
          voiceSocket: 'closed',
          warning:
            'Unable to reconnect after several attempts. Please refresh the page to resume.',
        })
        return
      }

      const attempt = reconnectAttemptsRef.current + 1
      reconnectAttemptsRef.current = attempt
      const delay = Math.min(
        RECONNECT_BASE_DELAY_MS * 2 ** (attempt - 1),
        RECONNECT_MAX_DELAY_MS
      )
      options.onConnectionStatus?.({
        message: `Voice connection dropped — reconnecting in ${Math.round(delay / 1000)}s (attempt ${attempt}/${RECONNECT_MAX_ATTEMPTS})`,
        voiceSocket: 'reconnecting',
        warning:
          'The voice session was interrupted. Attempting to restore it automatically.',
      })
      if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current)
      reconnectTimerRef.current = setTimeout(() => {
        reconnectTimerRef.current = null
        connectRef
          .current?.()
          .catch(err => console.warn('Reconnect attempt failed:', err))
      }, delay)
    }
    wsRef.current = ws
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [options.agentId])

  const send = useCallback((data: any) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(typeof data === 'string' ? data : JSON.stringify(data))
    }
  }, [])

  const clearMessages = useCallback(() => {
    setMessages([])
    conversationRecording.current = []
    audioRecording.current = []
    conversationIdRef.current = null
    if (saveTimerRef.current) clearTimeout(saveTimerRef.current)
    pendingSaveRef.current = false
  }, [])

  useEffect(() => {
    connectRef.current = connect
  }, [connect])

  const getRecordings = useCallback(
    () => ({
      conversation: conversationRecording.current,
      audio: audioRecording.current,
    }),
    []
  )

  const getConversationId = useCallback(() => conversationIdRef.current, [])

  const saveConversationNow = useCallback(async () => {
    const conversationId = await ensureConversationCreated()
    if (!conversationId) return null

    if (saveTimerRef.current) {
      clearTimeout(saveTimerRef.current)
      saveTimerRef.current = null
    }

    const msgs = conversationRecording.current
    const transcript = msgs
      .map((m: any) => `${m.role}: ${m.content}`)
      .join('\n')
    await api.updateConversationMessages(conversationId, msgs, transcript)
    pendingSaveRef.current = false
    return conversationId
  }, [ensureConversationCreated])

  useEffect(() => {
    connect()
    return () => {
      manualCloseRef.current = true
      reconnectAttemptsRef.current = 0
      if (reconnectTimerRef.current) {
        clearTimeout(reconnectTimerRef.current)
        reconnectTimerRef.current = null
      }
      stopKeepAlive()
      wsRef.current?.close()
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current)
    }
  }, [connect, stopKeepAlive])

  return {
    connected,
    messages,
    send,
    clearMessages,
    getRecordings,
    getConversationId,
    saveConversationNow,
  }
}
