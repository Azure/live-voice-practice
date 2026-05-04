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
    conversationId?: string | null
  ): Promise<Assessment> {
    const referenceText = extractUserText(conversationMessages)

    const res = await fetch('/api/analyze', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        scenario_id: scenarioId,
        transcript,
        audio_data: audioData,
        reference_text: referenceText,
        conversation_messages: conversationMessages,
        ...(conversationId ? { conversation_id: conversationId } : {}),
      }),
    })
    if (!res.ok) throw new Error('Analysis failed')
    return res.json()
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

  async deleteConversation(conversationId: string): Promise<{ success: boolean }> {
    const res = await fetch(`/api/conversations/${encodeURIComponent(conversationId)}`, {
      method: 'DELETE',
    })
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

  async getConversation(conversationId: string): Promise<ConversationDetailData> {
    const res = await fetch(`/api/conversations/${encodeURIComponent(conversationId)}`)
    if (!res.ok) throw new Error('Failed to get conversation')
    return res.json()
  },

}
