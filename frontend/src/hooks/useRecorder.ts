/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useRef, useState, useCallback } from 'react'
import { api } from '../services/api'

const audioProcessorCode = `
class AudioRecorderProcessor extends AudioWorkletProcessor {
  constructor() {
    super()
    this.recording = false
    this.buffer = []
    this.port.onmessage = e => {
      if (e.data.command === 'START') this.recording = true
      else if (e.data.command === 'STOP') {
        this.recording = false
        if (this.buffer.length) this.sendBuffer()
      }
    }
  }
  sendBuffer() {
    if (this.buffer.length) {
      this.port.postMessage({
        eventType: 'audio',
        audioData: new Float32Array(this.buffer)
      })
      this.buffer = []
    }
  }
  process(inputs) {
    if (inputs[0]?.length && this.recording) {
      this.buffer.push(...inputs[0][0])
      if (this.buffer.length >= 2400) this.sendBuffer()
    }
    return true
  }
}
registerProcessor('audio-recorder', AudioRecorderProcessor)
`

function buildMicErrorMessage(err: unknown): string {
  if (!(err instanceof Error)) {
    return 'Could not start recording. An unexpected error occurred while accessing the microphone.'
  }
  switch (err.name) {
    case 'NotFoundError':
    case 'OverconstrainedError':
      return (
        'No microphone was detected on this device. ' +
        'If you are connected through Azure Bastion HTML5, mic redirection is not supported — ' +
        'connect with the Bastion native client (`az network bastion rdp`) or from a device with a microphone.'
      )
    case 'NotAllowedError':
    case 'SecurityError':
      return (
        'Microphone permission was denied. Allow microphone access in your browser ' +
        '(check the address bar and site settings) and try again.'
      )
    case 'NotReadableError':
      return (
        'The microphone is currently in use by another application or driver. ' +
        'Close other apps using the mic and try again.'
      )
    case 'AbortError':
      return 'Recording was aborted before it could start. Please try again.'
    default:
      return `Could not start recording: ${err.name || 'UnknownError'} — ${err.message}`
  }
}

export function useRecorder(onAudioChunk: (base64: string) => void) {
  const [recording, setRecording] = useState(false)
  const [recordingError, setRecordingError] = useState<string | null>(null)
  const audioCtxRef = useRef<AudioContext | null>(null)
  const workletRef = useRef<AudioWorkletNode | null>(null)
  const audioRecording = useRef<any[]>([])

  const initAudio = useCallback(async () => {
    if (audioCtxRef.current) return

    const audioCtx = new AudioContext({ sampleRate: 24000 })
    const blob = new Blob([audioProcessorCode], {
      type: 'application/javascript',
    })
    const url = URL.createObjectURL(blob)
    await audioCtx.audioWorklet.addModule(url)
    URL.revokeObjectURL(url)
    audioCtxRef.current = audioCtx
  }, [])

  const startRecording = useCallback(async () => {
    setRecordingError(null)
    api.clientLog('info', 'recorder.start.requested', {
      hasMediaDevices: !!navigator.mediaDevices,
      hasGetUserMedia: !!navigator.mediaDevices?.getUserMedia,
      isSecureContext: window.isSecureContext,
      userAgent: navigator.userAgent,
    })

    try {
      await initAudio()
    } catch (err) {
      const message =
        err instanceof Error
          ? `Audio engine failed to initialize: ${err.message}`
          : 'Audio engine failed to initialize.'
      setRecordingError(message)
      api.clientLog('error', 'recorder.audioworklet.init_failed', {
        name: (err as Error)?.name,
        message: (err as Error)?.message,
      })
      return
    }
    const audioCtx = audioCtxRef.current!

    if (audioCtx.state === 'suspended') {
      await audioCtx.resume()
    }

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      const msg =
        'Microphone access is not available in this browser context. ' +
        'getUserMedia requires a secure (HTTPS) context and is not supported in some embedded clients.'
      setRecordingError(msg)
      api.clientLog('error', 'recorder.no_getusermedia', {
        isSecureContext: window.isSecureContext,
      })
      return
    }

    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          sampleRate: 24000,
          echoCancellation: true,
        },
      })
    } catch (err) {
      const friendly = buildMicErrorMessage(err)
      setRecordingError(friendly)
      api.clientLog('error', 'recorder.getusermedia_failed', {
        name: (err as Error)?.name,
        message: (err as Error)?.message,
      })
      return
    }

    const tracks = stream.getAudioTracks()
    api.clientLog('info', 'recorder.getusermedia_ok', {
      trackCount: tracks.length,
      trackLabel: tracks[0]?.label,
      trackSettings: tracks[0]?.getSettings?.(),
    })

    const source = audioCtx.createMediaStreamSource(stream)
    const worklet = new AudioWorkletNode(audioCtx, 'audio-recorder')

    worklet.port.onmessage = e => {
      if (e.data.eventType === 'audio') {
        const float32 = e.data.audioData
        const int16 = new Int16Array(float32.length)
        for (let i = 0; i < float32.length; i++) {
          int16[i] = Math.max(-32768, Math.min(32767, float32[i] * 32767))
        }
        const base64 = btoa(
          String.fromCharCode(...new Uint8Array(int16.buffer))
        )
        audioRecording.current.push({
          type: 'user',
          data: base64,
          timestamp: new Date().toISOString(),
        })
        onAudioChunk(base64)
      }
    }

    source.connect(worklet)
    worklet.connect(audioCtx.destination)
    worklet.port.postMessage({ command: 'START' })

    workletRef.current = worklet
    setRecording(true)
  }, [onAudioChunk, initAudio])

  const stopRecording = useCallback(() => {
    if (workletRef.current) {
      workletRef.current.port.postMessage({ command: 'STOP' })
      workletRef.current.disconnect()
      workletRef.current = null
    }
    setRecording(false)
  }, [])

  const toggleRecording = useCallback(async () => {
    if (recording) {
      stopRecording()
    } else {
      await startRecording()
    }
  }, [recording, startRecording, stopRecording])

  const getAudioRecording = useCallback(() => audioRecording.current, [])

  const clearRecordingError = useCallback(() => setRecordingError(null), [])

  return {
    recording,
    recordingError,
    clearRecordingError,
    toggleRecording,
    getAudioRecording,
  }
}
