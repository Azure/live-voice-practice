/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

export interface Scenario {
  id: string
  name: string
  description: string
}

export interface CustomScenarioData {
  systemPrompt: string
}

export interface CustomScenario extends Scenario {
  is_custom: true
  scenarioData: CustomScenarioData
  createdAt: string
  updatedAt: string
}

export interface Message {
  id: string
  role: 'user' | 'assistant'
  content: string
  timestamp: Date
}

export interface CriterionScore {
  score: number
  justification: string
}

export interface Assessment {
  ai_assessment?: {
    speaking_tone_style?: {
      professional_tone: number
      active_listening: number
      engagement_quality: number
      total: number
    }
    conversation_content?: {
      needs_assessment: number
      value_proposition: number
      objection_handling: number
      total: number
    }
    criteria_scores?: Record<string, CriterionScore>
    overall_score: number
    passed?: boolean
    strengths: string[]
    improvements: string[]
    specific_feedback?: string
  }
  pronunciation_assessment?: {
    accuracy_score: number
    fluency_score: number
    completeness_score: number
    prosody_score?: number
    pronunciation_score: number
    words?: Array<{
      word: string
      accuracy: number
      error_type: string
    }>
  }
}

export interface AvatarOption {
  value: string
  label: string
  isPhotoAvatar: boolean
}

export const AVATAR_OPTIONS: AvatarOption[] = [
  {
    value: 'audio-only',
    label: 'Audio Only (No Avatar)',
    isPhotoAvatar: false,
  },
  {
    value: 'lisa-casual-sitting',
    label: 'Lisa (Casual Sitting)',
    isPhotoAvatar: false,
  },
  { value: 'riya', label: 'Riya (Photo)', isPhotoAvatar: true },
  { value: 'simone', label: 'Simone (Photo)', isPhotoAvatar: true },
]

export const DEFAULT_AVATAR = 'lisa-casual-sitting'
