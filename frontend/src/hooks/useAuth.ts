/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useEffect, useState } from 'react'
import { api } from '../services/api'

interface AuthUser {
  user_id: string
  name: string
  email: string
  is_admin: boolean
  role: string
}

interface AuthState {
  authenticated: boolean
  user: AuthUser | null
  loading: boolean
  isTrainer: boolean
}

export function useAuth(): AuthState {
  const [state, setState] = useState<AuthState>({
    authenticated: false,
    user: null,
    loading: true,
    isTrainer: false,
  })

  useEffect(() => {
    api
      .getMe()
      .then(data => {
        if (data.authenticated) {
          setState({
            authenticated: true,
            user: {
              user_id: data.user_id,
              name: data.name,
              email: data.email,
              is_admin: data.is_admin,
              role: data.role || 'trainee',
            },
            loading: false,
            isTrainer: data.role === 'trainer',
          })
        } else {
          setState({ authenticated: false, user: null, loading: false, isTrainer: false })
        }
      })
      .catch(() => {
        setState({ authenticated: false, user: null, loading: false, isTrainer: false })
      })
  }, [])

  return state
}
