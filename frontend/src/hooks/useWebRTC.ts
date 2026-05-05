/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useRef, useCallback, useEffect } from 'react'
import { api } from '../services/api'

export function useWebRTC(onSendOffer: (sdp: string) => void) {
  const pcRef = useRef<RTCPeerConnection | null>(null)
  const videoRef = useRef<HTMLVideoElement | null>(null)

  const setupWebRTC = useCallback(
    async (iceServers: any, username?: string, password?: string) => {
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

      const pc = new RTCPeerConnection({
        iceServers: servers,
        bundlePolicy: 'max-bundle',
      })

      pc.onicecandidate = e => {
        if (e.candidate) {
          api.clientLog('debug', 'webrtc.icecandidate', {
            type: e.candidate.type,
            protocol: e.candidate.protocol,
            address: e.candidate.address,
            port: e.candidate.port,
            relatedAddress: e.candidate.relatedAddress,
          })
        } else if (pc.localDescription) {
          api.clientLog('info', 'webrtc.ice.gather_complete_sending_offer')
          const sdp = btoa(
            JSON.stringify({
              type: 'offer',
              sdp: pc.localDescription.sdp,
            })
          )
          onSendOffer(sdp)
        }
      }

      pc.onicecandidateerror = (e: any) => {
        api.clientLog('warning', 'webrtc.icecandidate_error', {
          errorCode: e.errorCode,
          errorText: e.errorText,
          url: e.url,
          hostCandidate: e.hostCandidate,
        })
      }

      pc.oniceconnectionstatechange = () => {
        api.clientLog('info', 'webrtc.iceconnectionstate', {
          state: pc.iceConnectionState,
        })
      }

      pc.onicegatheringstatechange = () => {
        api.clientLog('info', 'webrtc.icegatheringstate', {
          state: pc.iceGatheringState,
        })
      }

      pc.onconnectionstatechange = () => {
        api.clientLog('info', 'webrtc.connectionstate', {
          state: pc.connectionState,
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
          videoRef.current.srcObject = e.streams[0]
          videoRef.current.play().catch(err => {
            api.clientLog('warning', 'webrtc.video_play_failed', {
              name: err?.name,
              message: err?.message,
            })
          })
        } else if (e.track.kind === 'audio') {
          const audio = document.createElement('audio')
          audio.srcObject = e.streams[0]
          audio.autoplay = true
          audio.style.display = 'none'
          document.body.appendChild(audio)
        }
      }

      pc.addTransceiver('video', { direction: 'recvonly' })
      pc.addTransceiver('audio', { direction: 'recvonly' })

      const offer = await pc.createOffer()
      await pc.setLocalDescription(offer)

      pcRef.current = pc
    },
    [onSendOffer]
  )

  const handleAnswer = useCallback(async (msg: any) => {
    if (!pcRef.current || pcRef.current.signalingState !== 'have-local-offer') {
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
    } else {
      api.clientLog('warning', 'webrtc.answer_no_sdp', { keys: Object.keys(msg) })
    }
  }, [])

  useEffect(() => {
    return () => {
      pcRef.current?.close()
    }
  }, [])

  return {
    setupWebRTC,
    handleAnswer,
    videoRef,
  }
}
