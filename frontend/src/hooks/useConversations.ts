/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useCallback, useEffect, useState } from 'react'
import { api } from '../services/api'
import { ConversationSummary } from '../types'

const PAGE_SIZE = 20

export function useConversations() {
  const [conversations, setConversations] = useState<ConversationSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [total, setTotal] = useState(0)
  const [currentPage, setCurrentPage] = useState(1)
  const [sortBy, setSortBy] = useState('created_at')
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc')

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))

  const fetchConversations = useCallback(async () => {
    setLoading(true)
    try {
      const offset = (currentPage - 1) * PAGE_SIZE
      const result = await api.listConversations(PAGE_SIZE, offset, sortBy, sortOrder)
      setConversations(result.conversations)
      setTotal(result.total)
    } catch (err) {
      console.error('Failed to load conversations:', err)
      setConversations([])
      setTotal(0)
    } finally {
      setLoading(false)
    }
  }, [currentPage, sortBy, sortOrder])

  useEffect(() => {
    fetchConversations()
  }, [fetchConversations])

  const setPage = useCallback((page: number) => {
    setCurrentPage(Math.max(1, Math.min(page, totalPages)))
  }, [totalPages])

  const setSort = useCallback((column: string, order: 'asc' | 'desc') => {
    setSortBy(column)
    setSortOrder(order)
    setCurrentPage(1)
  }, [])

  const refresh = useCallback(() => {
    fetchConversations()
  }, [fetchConversations])

  return {
    conversations,
    loading,
    total,
    totalPages,
    currentPage,
    sortBy,
    sortOrder,
    setPage,
    setSort,
    refresh,
  }
}
