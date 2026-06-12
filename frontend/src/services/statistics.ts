/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

export interface StatisticsFilters {
  from?: string
  to?: string
  scenarioIds?: string[]
  rubricIds?: string[]
  includeInProgress?: boolean
}

export interface OverviewKpis {
  totalPractices: number
  analyzedPractices: number
  uniqueTrainees: number
  averageScorePercent: number | null
  passRatePercent: number | null
}

export interface PracticesOverTimePoint {
  date: string
  count: number
}

export interface AverageScoreOverTimePoint {
  date: string
  avgScorePercent: number
}

export interface ScenarioPerformance {
  scenarioId: string
  count: number
  avgScorePercent: number | null
  passRatePercent: number | null
}

export interface CriterionPerformance {
  criterionId: string
  name: string
  avgScorePercent: number
  count: number
}

export interface ScoreDistributionBucket {
  bucket: string
  count: number
}

export interface ScenarioDropOff {
  scenarioId: string
  started: number
  analyzed: number
  dropOffPercent: number
}

export interface StatisticsOverview {
  kpis: OverviewKpis
  practicesOverTime: PracticesOverTimePoint[]
  averageScoreOverTime: AverageScoreOverTimePoint[]
  performanceByScenario: ScenarioPerformance[]
  weakestCriteria: CriterionPerformance[]
  scoreDistribution: ScoreDistributionBucket[]
  dropOffByScenario: ScenarioDropOff[]
  windowDays: number
  windowCapped: boolean
  generatedAt: string
}

export interface TraineeRow {
  userId: string
  displayName: string
  practices: number
  lastPracticeAt: string | null
  avgScorePercent: number | null
  passRatePercent: number | null
  recentScores: number[]
  trendDelta: number | null
}

export interface TraineesResponse {
  items: TraineeRow[]
  total: number
  limit: number
  offset: number
  windowDays: number
  windowCapped: boolean
  generatedAt: string
}

export interface TraineesQuery extends StatisticsFilters {
  sortBy?: string
  sortOrder?: 'asc' | 'desc'
  limit?: number
  offset?: number
}

export interface TraineeTotals {
  practices: number
  analyzedPractices: number
  avgScorePercent: number | null
  passRatePercent: number | null
}

export interface ScoreTimePoint {
  date: string
  scorePercent: number
  scenarioId: string
  conversationId: string
}

export interface TraineeDetail {
  userId: string
  displayName: string
  totals: TraineeTotals
  scoreTimeSeries: ScoreTimePoint[]
  criterionAverages: CriterionPerformance[]
  scenarioBreakdown: ScenarioPerformance[]
  recommendations: string[]
  windowDays: number
  windowCapped: boolean
  generatedAt: string
}

function buildQuery(filters: StatisticsFilters): string {
  const params = new URLSearchParams()
  if (filters.from) params.set('from', filters.from)
  if (filters.to) params.set('to', filters.to)
  for (const scenarioId of filters.scenarioIds ?? []) {
    params.append('scenarioIds', scenarioId)
  }
  for (const rubricId of filters.rubricIds ?? []) {
    params.append('rubricIds', rubricId)
  }
  if (filters.includeInProgress) {
    params.set('includeInProgress', 'true')
  }
  const query = params.toString()
  return query ? `?${query}` : ''
}

export const statisticsApi = {
  async getOverview(
    filters: StatisticsFilters = {}
  ): Promise<StatisticsOverview> {
    const res = await fetch(
      `/api/admin/statistics/overview${buildQuery(filters)}`
    )
    if (!res.ok) {
      throw new Error(`Failed to load statistics overview (HTTP ${res.status})`)
    }
    return res.json()
  },

  async getTrainees(query: TraineesQuery = {}): Promise<TraineesResponse> {
    const params = new URLSearchParams(buildQuery(query).replace(/^\?/, ''))
    if (query.sortBy) params.set('sort_by', query.sortBy)
    if (query.sortOrder) params.set('sort_order', query.sortOrder)
    if (query.limit !== undefined) params.set('limit', String(query.limit))
    if (query.offset !== undefined) params.set('offset', String(query.offset))
    const suffix = params.toString() ? `?${params.toString()}` : ''
    const res = await fetch(`/api/admin/statistics/trainees${suffix}`)
    if (!res.ok) {
      throw new Error(`Failed to load trainees (HTTP ${res.status})`)
    }
    return res.json()
  },

  async getTraineeDetail(
    identifier: string,
    filters: StatisticsFilters = {}
  ): Promise<TraineeDetail> {
    const res = await fetch(
      `/api/admin/statistics/trainees/${encodeURIComponent(identifier)}${buildQuery(filters)}`
    )
    if (res.status === 404) {
      throw new Error('Trainee not found')
    }
    if (!res.ok) {
      throw new Error(`Failed to load trainee detail (HTTP ${res.status})`)
    }
    return res.json()
  },

  buildExportUrl(filters: StatisticsFilters = {}): string {
    return `/api/admin/statistics/export${buildQuery(filters)}`
  },
}
