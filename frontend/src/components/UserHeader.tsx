/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Button, Link, Text, makeStyles, tokens } from '@fluentui/react-components'
import { SignOut24Regular } from '@fluentui/react-icons'
import { useNavigate } from 'react-router-dom'

const useStyles = makeStyles({
  header: {
    position: 'fixed',
    top: 0,
    right: 0,
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalS,
    padding: `${tokens.spacingVerticalS} ${tokens.spacingHorizontalL}`,
    zIndex: 1000,
  },
})

interface Props {
  userName: string | null | undefined
  authenticated: boolean
  role?: string
  isTrainer?: boolean
}

export function UserHeader({ userName, authenticated, role, isTrainer }: Props) {
  const styles = useStyles()
  const navigate = useNavigate()

  if (!authenticated) return null

  return (
    <div className={styles.header}>
      {isTrainer && (
        <Link onClick={() => navigate('/admin')}>Admin</Link>
      )}
      <Text size={300} weight="semibold">
        {userName || 'User'}
      </Text>
      {role && (
        <Text size={200} style={{ opacity: 0.7 }}>
          ({role === 'trainer' ? 'Trainer' : 'Trainee'})
        </Text>
      )}
      <Button
        appearance="subtle"
        size="small"
        icon={<SignOut24Regular />}
        onClick={() => {
          window.location.href = '/.auth/logout'
        }}
      >
        Log off
      </Button>
    </div>
  )
}
