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

/** Scored criterion with explanation (new format) or plain number (legacy stored data). */
export type ScoredCriterion = { score: number; explanation: string } | number

/** Structured improvement recommendation tied to a specific criterion. */
export interface Improvement {
  criterion: string
  score: number
  max_score: number
  recommendation: string
}

/** An improvement entry can be the new structured format or a legacy plain string. */
export type ImprovementEntry = Improvement | string

export interface Assessment {
  ai_assessment?: {
    speaking_tone_style?: {
      professional_tone: ScoredCriterion
      active_listening: ScoredCriterion
      engagement_quality: ScoredCriterion
      total: number
    }
    conversation_content?: {
      needs_assessment: ScoredCriterion
      value_proposition: ScoredCriterion
      objection_handling: ScoredCriterion
      total: number
    }
    criteria_scores?: Record<string, CriterionScore>
    overall_score: number
    passed?: boolean
    strengths: string[]
    improvements: ImprovementEntry[]
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

export interface ConversationSummary {
  id: string
  user_id: string
  scenario_id: string
  scenario_name?: string
  assessment?: Assessment | null
  metadata?: { user_name?: string; user_email?: string }
  status?: string
  created_at: string
  updated_at: string
}

export interface ConversationListResponse {
  conversations: ConversationSummary[]
  total: number
  limit: number
  offset: number
}

export interface ConversationDetailData {
  id: string
  user_id: string
  scenario_id: string
  transcript?: string
  messages: Array<{ role: string; content: string }>
  assessment?: Assessment | null
  status?: string
  metadata?: { user_name?: string; user_email?: string }
  created_at: string
  updated_at: string
}
