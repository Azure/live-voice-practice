/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Assessment,
  AVATAR_OPTIONS,
  ConversationDetailData,
  ConversationListResponse,
  Scenario,
} from '../types'

const MAX_LEGACY_ANALYZE_AUDIO_PAYLOAD_CHARS = 60000

export interface AvatarConfig {
  character: string
  style: string
  is_photo_avatar: boolean
}

export function parseAvatarValue(value: string): AvatarConfig | null {
  if (value === 'audio-only') {
    return null
  }

  const avatarOption = AVATAR_OPTIONS.find(opt => opt.value === value)
  const isPhotoAvatar = avatarOption?.isPhotoAvatar ?? false

  if (isPhotoAvatar) {
    return { character: value.toLowerCase(), style: '', is_photo_avatar: true }
  }

  const parts = value.split('-')
  const character = parts[0].toLowerCase()
  const style = parts.length >= 2 ? parts.slice(1).join('-') : 'casual-sitting'

  return { character, style, is_photo_avatar: false }
}

function extractUserText(conversationMessages: any[]): string {
  return conversationMessages
    .filter(msg => msg.role === 'user')
    .map(msg => msg.content)
    .join(' ')
    .trim()
}

function estimateAudioPayloadChars(audioData: any[]): number {
  return audioData.reduce((total, chunk) => {
    const data = typeof chunk?.data === 'string' ? chunk.data : ''
    return total + data.length
  }, 0)
}

async function getErrorMessage(res: Response): Promise<string> {
  const contentType = res.headers.get('content-type') ?? ''
  try {
    if (contentType.includes('application/json')) {
      const detail = await res.json()
      const code = detail.code ? `[${detail.code}] ` : ''
      return `${code}${detail.error ?? detail.detail ?? `HTTP ${res.status}`}`
    }
    const text = await res.text()
    return text || `HTTP ${res.status}`
  } catch {
    return `HTTP ${res.status}`
  }
}

export const api = {
  async getConfig() {
    const res = await fetch('/api/config')
    return res.json()
  },

  async getScenarios(): Promise<Scenario[]> {
    const res = await fetch('/api/scenarios')
    if (!res.ok) {
      // Fail loud: previously returning res.json() blindly meant a 503 with
      // an error object got rendered as if it were the scenarios list,
      // crashing downstream UI silently. Now we surface the diagnostic.
      let detail: { error?: string; code?: string; hint?: string } = {}
      try {
        detail = await res.json()
      } catch {
        // body wasn't JSON; that's fine, we'll throw a generic message
      }
      const code = detail.code ? `[${detail.code}] ` : ''
      const message = detail.error ?? `HTTP ${res.status}`
      const hint = detail.hint ? ` — ${detail.hint}` : ''
      throw new Error(`${code}${message}${hint}`)
    }
    return res.json()
  },

  async createAgent(scenarioId: string, avatarConfig?: AvatarConfig | null) {
    const res = await fetch('/api/agents/create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        scenario_id: scenarioId,
        avatar: avatarConfig ?? undefined,
      }),
    })
    if (!res.ok) throw new Error('Failed to create agent')
    return res.json()
  },

  async analyzeConversation(
    scenarioId: string,
    transcript: string,
    audioData: any[],
    conversationMessages: any[],
    conversationId?: string | null,
    agentId?: string | null
  ): Promise<Assessment> {
    const referenceText = extractUserText(conversationMessages)
    const audioPayloadChars = estimateAudioPayloadChars(audioData)
    const shouldSendMessages = !conversationId
    const shouldSendLegacyAudio =
      !agentId && audioPayloadChars <= MAX_LEGACY_ANALYZE_AUDIO_PAYLOAD_CHARS
    const payload = {
      scenario_id: scenarioId,
      ...(shouldSendMessages
        ? { conversation_messages: conversationMessages }
        : {}),
      ...(shouldSendLegacyAudio ? { audio_data: audioData } : {}),
      ...(conversationId ? { conversation_id: conversationId } : {}),
      ...(agentId ? { agent_id: agentId } : {}),
    }
    const estimatedRequestChars = JSON.stringify(payload).length
    const audioSource = agentId
      ? 'websocket-session'
      : shouldSendLegacyAudio
        ? 'legacy-request-body'
        : 'none'

    this.clientLog('info', 'analysis.request.start', {
      scenarioId,
      transcriptChars: transcript.length,
      referenceChars: referenceText.length,
      messages: conversationMessages.length,
      audioChunks: audioData.length,
      audioPayloadChars,
      audioSource,
      hasConversationId: !!conversationId,
      hasAgentId: !!agentId,
      sendsMessages: shouldSendMessages,
      estimatedRequestChars,
    })

    const res = await fetch('/api/analyze', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    if (!res.ok) {
      const message = await getErrorMessage(res)
      this.clientLog('error', 'analysis.request.failed', {
        status: res.status,
        message,
        audioPayloadChars,
        audioSource,
        estimatedRequestChars,
      })
      throw new Error(message)
    }
    const result = await res.json()
    this.clientLog('info', 'analysis.request.succeeded', {
      hasAiAssessment: !!result.ai_assessment,
      hasPronunciationAssessment: !!result.pronunciation_assessment,
      conversationId: result.conversation_id,
      diagnostics: result.diagnostics,
    })
    return result
  },

  async createConversation(
    scenarioId: string,
    messages: any[] = []
  ): Promise<{ conversation_id: string }> {
    const res = await fetch('/api/conversations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        scenario_id: scenarioId,
        messages,
      }),
    })
    if (!res.ok) throw new Error('Failed to create conversation')
    return res.json()
  },

  async updateConversationMessages(
    conversationId: string,
    messages: any[],
    transcript: string = ''
  ): Promise<{ success: boolean }> {
    const res = await fetch(`/api/conversations/${conversationId}/messages`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages, transcript }),
    })
    if (!res.ok) throw new Error('Failed to update conversation')
    return res.json()
  },

  async getMe(): Promise<any> {
    const res = await fetch('/api/me')
    return res.json()
  },

  async deleteConversation(
    conversationId: string
  ): Promise<{ success: boolean }> {
    const res = await fetch(
      `/api/conversations/${encodeURIComponent(conversationId)}`,
      {
        method: 'DELETE',
      }
    )
    if (!res.ok) throw new Error('Failed to delete conversation')
    return res.json()
  },

  async listConversations(
    limit: number = 20,
    offset: number = 0,
    sortBy: string = 'created_at',
    sortOrder: string = 'desc',
    all?: boolean
  ): Promise<ConversationListResponse> {
    const params = new URLSearchParams({
      limit: String(limit),
      offset: String(offset),
      sort_by: sortBy,
      sort_order: sortOrder,
    })
    if (all) {
      params.set('all', 'true')
    }
    const res = await fetch(`/api/conversations?${params}`)
    if (!res.ok) throw new Error('Failed to list conversations')
    return res.json()
  },

  async getConversation(
    conversationId: string
  ): Promise<ConversationDetailData> {
    const res = await fetch(
      `/api/conversations/${encodeURIComponent(conversationId)}`
    )
    if (!res.ok) throw new Error('Failed to get conversation')
    return res.json()
  },

  /**
   * Fire-and-forget diagnostic log to the backend so client-side WebRTC /
   * getUserMedia / avatar pipeline events show up in container logs without
   * requiring the operator to attach browser DevTools through Bastion.
   *
   * Always resolves; failures are intentionally swallowed (and mirrored to
   * console) so logging never breaks the UX.
   */
  clientLog(
    level: 'debug' | 'info' | 'warning' | 'error',
    event: string,
    detail?: unknown
  ): void {
    try {
      const consoleFn =
        level === 'error'
          ? console.error
          : level === 'warning'
            ? console.warn
            : console.info
      consoleFn(`[client-log] ${event}`, detail ?? '')
      void fetch('/api/client-log', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ level, event, detail }),
        keepalive: true,
      }).catch(() => {
        /* swallow — diagnostic must never break UX */
      })
    } catch {
      /* swallow */
    }
  },
}
