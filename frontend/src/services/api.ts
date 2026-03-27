/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
    Assessment,
    AVATAR_OPTIONS,
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
    conversationMessages: any[]
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
      }),
    })
    if (!res.ok) throw new Error('Analysis failed')
    return res.json()
  },

}
