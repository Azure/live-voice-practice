/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Button, Text, makeStyles, tokens } from '@fluentui/react-components'
import { SignOut24Regular } from '@fluentui/react-icons'

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
}

export function UserHeader({ userName, authenticated }: Props) {
  const styles = useStyles()

  if (!authenticated) return null

  return (
    <div className={styles.header}>
      <Text size={300} weight="semibold">
        {userName || 'User'}
      </Text>
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
