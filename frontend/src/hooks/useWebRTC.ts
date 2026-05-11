/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useRef, useCallback, useEffect } from 'react'
import { api } from '../services/api'

export interface AvatarConnectionStatus {
  message: string
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

export function useWebRTC(
  onSendOffer: (sdp: string) => void,
  onStatus?: (status: AvatarConnectionStatus) => void
) {
  const pcRef = useRef<RTCPeerConnection | null>(null)
  const videoRef = useRef<HTMLVideoElement | null>(null)
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const offerTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const setupWebRTC = useCallback(
    async (iceServers: any, username?: string, password?: string) => {
      pcRef.current?.close()
      audioRef.current?.remove()
      audioRef.current = null
      if (offerTimerRef.current) {
        clearTimeout(offerTimerRef.current)
        offerTimerRef.current = null
      }

      let servers = Array.isArray(iceServers)
        ? iceServers
        : [{ urls: iceServers }]
      if (username && password) {
        servers = servers.map(s => ({
          urls: typeof s === 'string' ? s : s.urls,
          username,
          credential: password,
          credentialType: 'password' as const,
        }))
      }

      api.clientLog('info', 'webrtc.setup.start', {
        iceServerCount: servers.length,
        urls: servers.map(s => (typeof s === 'string' ? s : s.urls)),
      })
      onStatus?.({
        message: 'Preparing the browser video connection',
        browserConnection: 'new',
        networkRelay: 'starting',
        media: { audio: false, video: false },
      })

      const pc = new RTCPeerConnection({
        iceServers: servers,
        bundlePolicy: 'max-bundle',
      })
      const candidateTypes = new Set<string>()
      let offerSent = false

      const sendOfferOnce = (reason: string) => {
        if (offerSent || !pc.localDescription) return
        offerSent = true
        if (offerTimerRef.current) {
          clearTimeout(offerTimerRef.current)
          offerTimerRef.current = null
        }
        api.clientLog('info', 'webrtc.offer_sending', {
          reason,
          iceGatheringState: pc.iceGatheringState,
          candidateTypes: [...candidateTypes],
          sdpLength: pc.localDescription.sdp.length,
        })
        onStatus?.({
          message: 'Sending browser connection details to the avatar service',
          browserConnection: pc.connectionState,
          networkRelay: pc.iceConnectionState,
          gathering: pc.iceGatheringState,
          candidateTypes: [...candidateTypes],
        })
        const sdp = btoa(
          JSON.stringify({
            type: 'offer',
            sdp: pc.localDescription.sdp,
          })
        )
        onSendOffer(sdp)
      }

      pc.onicecandidate = e => {
        if (e.candidate) {
          if (e.candidate.type) {
            candidateTypes.add(e.candidate.type)
          }
          api.clientLog('debug', 'webrtc.icecandidate', {
            type: e.candidate.type,
            protocol: e.candidate.protocol,
            address: e.candidate.address,
            port: e.candidate.port,
            relatedAddress: e.candidate.relatedAddress,
          })
          onStatus?.({
            message: 'Finding a network path for the avatar video',
            browserConnection: pc.connectionState,
            networkRelay: pc.iceConnectionState,
            gathering: pc.iceGatheringState,
            candidateTypes: [...candidateTypes],
          })
        } else if (pc.localDescription) {
          sendOfferOnce('ice-candidate-complete')
        }
      }

      pc.onicecandidateerror = (e: any) => {
        api.clientLog('warning', 'webrtc.icecandidate_error', {
          errorCode: e.errorCode,
          errorText: e.errorText,
          url: e.url,
          hostCandidate: e.hostCandidate,
        })
        onStatus?.({
          message: 'Network relay reported a connection error',
          browserConnection: pc.connectionState,
          networkRelay: pc.iceConnectionState,
          gathering: pc.iceGatheringState,
          candidateTypes: [...candidateTypes],
          warning:
            e.errorText || 'The browser could not reach the media relay.',
        })
      }

      pc.oniceconnectionstatechange = () => {
        api.clientLog('info', 'webrtc.iceconnectionstate', {
          state: pc.iceConnectionState,
        })
        onStatus?.({
          message: 'Checking the avatar media path',
          browserConnection: pc.connectionState,
          networkRelay: pc.iceConnectionState,
          gathering: pc.iceGatheringState,
          candidateTypes: [...candidateTypes],
          warning:
            pc.iceConnectionState === 'failed'
              ? 'The browser could not establish the avatar media path.'
              : undefined,
        })
      }

      pc.onicegatheringstatechange = () => {
        api.clientLog('info', 'webrtc.icegatheringstate', {
          state: pc.iceGatheringState,
        })
        onStatus?.({
          message:
            pc.iceGatheringState === 'complete'
              ? 'Network path found'
              : 'Finding a network path for the avatar video',
          browserConnection: pc.connectionState,
          networkRelay: pc.iceConnectionState,
          gathering: pc.iceGatheringState,
          candidateTypes: [...candidateTypes],
        })
        if (pc.iceGatheringState === 'complete') {
          sendOfferOnce('ice-gathering-complete')
        }
      }

      pc.onconnectionstatechange = () => {
        api.clientLog('info', 'webrtc.connectionstate', {
          state: pc.connectionState,
        })
        onStatus?.({
          message:
            pc.connectionState === 'connected'
              ? 'Avatar media connection established'
              : 'Connecting the avatar media stream',
          browserConnection: pc.connectionState,
          networkRelay: pc.iceConnectionState,
          gathering: pc.iceGatheringState,
          candidateTypes: [...candidateTypes],
          warning:
            pc.connectionState === 'failed'
              ? 'The avatar media connection failed.'
              : undefined,
        })
      }

      pc.onsignalingstatechange = () => {
        api.clientLog('debug', 'webrtc.signalingstate', {
          state: pc.signalingState,
        })
      }

      pc.ontrack = e => {
        api.clientLog('info', 'webrtc.ontrack', {
          kind: e.track.kind,
          id: e.track.id,
          readyState: e.track.readyState,
          streamCount: e.streams.length,
        })
        if (e.track.kind === 'video' && videoRef.current) {
          onStatus?.({
            message: 'Avatar video received',
            browserConnection: pc.connectionState,
            networkRelay: pc.iceConnectionState,
            gathering: pc.iceGatheringState,
            media: { video: true },
            candidateTypes: [...candidateTypes],
          })
          videoRef.current.srcObject = e.streams[0]
          videoRef.current.play().catch(err => {
            api.clientLog('warning', 'webrtc.video_play_failed', {
              name: err?.name,
              message: err?.message,
            })
            onStatus?.({
              message: 'Avatar video was received but playback did not start',
              browserConnection: pc.connectionState,
              networkRelay: pc.iceConnectionState,
              gathering: pc.iceGatheringState,
              media: { video: true },
              candidateTypes: [...candidateTypes],
              warning: 'The browser blocked or failed video playback.',
            })
          })
        } else if (e.track.kind === 'audio') {
          const audio = audioRef.current ?? document.createElement('audio')
          const stream = e.streams[0] ?? new MediaStream([e.track])
          onStatus?.({
            message: 'Avatar audio received',
            browserConnection: pc.connectionState,
            networkRelay: pc.iceConnectionState,
            gathering: pc.iceGatheringState,
            media: { audio: true },
            candidateTypes: [...candidateTypes],
          })

          audioRef.current = audio
          audio.srcObject = stream
          audio.autoplay = true
          audio.muted = false
          audio.volume = 1
          audio.style.display = 'none'

          e.track.onmute = () => {
            api.clientLog('warning', 'webrtc.audio_track_muted', {
              id: e.track.id,
            })
          }
          e.track.onunmute = () => {
            api.clientLog('info', 'webrtc.audio_track_unmuted', {
              id: e.track.id,
            })
          }
          e.track.onended = () => {
            api.clientLog('warning', 'webrtc.audio_track_ended', {
              id: e.track.id,
            })
          }

          if (!audio.isConnected) {
            document.body.appendChild(audio)
          }

          audio.play().then(
            () => {
              api.clientLog('info', 'webrtc.audio_play_started', {
                trackId: e.track.id,
                streamTrackCount: stream.getTracks().length,
              })
              onStatus?.({
                message: 'Avatar audio playback started',
                browserConnection: pc.connectionState,
                networkRelay: pc.iceConnectionState,
                gathering: pc.iceGatheringState,
                media: { audio: true },
                candidateTypes: [...candidateTypes],
              })
            },
            err => {
              api.clientLog('warning', 'webrtc.audio_play_failed', {
                name: err?.name,
                message: err?.message,
              })
              onStatus?.({
                message: 'Avatar audio was received but playback did not start',
                browserConnection: pc.connectionState,
                networkRelay: pc.iceConnectionState,
                gathering: pc.iceGatheringState,
                media: { audio: true },
                candidateTypes: [...candidateTypes],
                warning: 'The browser blocked or failed audio playback.',
              })
            }
          )
        }
      }

      pc.addTransceiver('video', { direction: 'recvonly' })
      pc.addTransceiver('audio', { direction: 'recvonly' })

      const offer = await pc.createOffer()
      await pc.setLocalDescription(offer)
      onStatus?.({
        message: 'Collecting network details for the avatar service',
        browserConnection: pc.connectionState,
        networkRelay: pc.iceConnectionState,
        gathering: pc.iceGatheringState,
        candidateTypes: [...candidateTypes],
      })

      offerTimerRef.current = setTimeout(() => {
        sendOfferOnce('ice-gathering-timeout')
      }, 8000)

      pcRef.current = pc
    },
    [onSendOffer, onStatus]
  )

  const handleAnswer = useCallback(
    async (msg: any) => {
      if (
        !pcRef.current ||
        pcRef.current.signalingState !== 'have-local-offer'
      ) {
        api.clientLog('warning', 'webrtc.answer_ignored', {
          hasPc: !!pcRef.current,
          signalingState: pcRef.current?.signalingState,
        })
        return
      }

      const sdp = msg.server_sdp
        ? JSON.parse(atob(msg.server_sdp)).sdp
        : msg.sdp || msg.answer

      if (sdp) {
        api.clientLog('info', 'webrtc.set_remote_description', {
          sdpLength: sdp.length,
        })
        await pcRef.current.setRemoteDescription({ type: 'answer', sdp })
        onStatus?.({
          message: 'Avatar service accepted the browser connection',
          browserConnection: pcRef.current.connectionState,
          networkRelay: pcRef.current.iceConnectionState,
          gathering: pcRef.current.iceGatheringState,
        })
      } else {
        api.clientLog('warning', 'webrtc.answer_no_sdp', {
          keys: Object.keys(msg),
        })
      }
    },
    [onStatus]
  )

  useEffect(() => {
    return () => {
      if (offerTimerRef.current) {
        clearTimeout(offerTimerRef.current)
      }
      pcRef.current?.close()
      audioRef.current?.remove()
    }
  }, [])

  return {
    setupWebRTC,
    handleAnswer,
    videoRef,
  }
}
