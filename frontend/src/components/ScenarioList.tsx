/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
    Button,
    Card,
    CardHeader,
    Dropdown,
    Label,
    Option,
    Text,
    makeStyles,
    tokens,
} from '@fluentui/react-components'
import { History24Regular, People24Regular } from '@fluentui/react-icons'
import { useState } from 'react'
import { AVATAR_OPTIONS, DEFAULT_AVATAR, Scenario } from '../types'

const useStyles = makeStyles({
  header: {
    gridColumn: '1 / -1',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: tokens.spacingVerticalS,
  },
  logo: {
    width: '80px',
    height: 'auto',
  },
  cardsGrid: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    gap: tokens.spacingVerticalM,
    gridColumn: '1 / span 2',
    width: '100%',
    '@media (max-width: 600px)': {
      gridTemplateColumns: '1fr',
    },
  },
  card: {
    cursor: 'pointer',
    transition: 'all 0.2s',
    '&:hover': {
      transform: 'translateY(-2px)',
      boxShadow: tokens.shadow16,
    },
  },
  selected: {
    backgroundColor: tokens.colorBrandBackground2,
  },
  actions: {
    gridColumn: '1 / -1',
    display: 'flex',
    justifyContent: 'flex-end',
    marginTop: tokens.spacingVerticalL,
    gap: tokens.spacingHorizontalM,
    alignItems: 'center',
  },
  avatarSelector: {
    display: 'flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalS,
    flexGrow: 1,
  },
  avatarDropdown: {
    minWidth: '200px',
  },
})

interface Props {
  scenarios: Scenario[]
  selectedScenario: string | null
  onSelect: (id: string) => void
  onStart: (avatarValue: string) => void
  isAuthenticated?: boolean
  onNavigateToConversations?: () => void
  isTrainer?: boolean
  onNavigateToAllPractices?: () => void
  appName?: string
}

export function ScenarioList({
  scenarios,
  selectedScenario,
  onSelect,
  onStart,
  isAuthenticated,
  onNavigateToConversations,
  isTrainer,
  onNavigateToAllPractices,
  appName,
}: Props) {
  const styles = useStyles()
  const [selectedAvatar, setSelectedAvatar] = useState(DEFAULT_AVATAR)

  return (
    <>
      <div className={styles.header}>
        <img
          src="/static/images/logo.png"
          alt={appName || 'Live Voice Practice'}
          className={styles.logo}
        />
        <Text size={500} weight="semibold">
          {appName || 'Select Training Scenario'}
        </Text>
      </div>

      {/* Server-side scenarios */}
      <div className={styles.cardsGrid}>
        {scenarios.map(scenario => {
          const isSelected = selectedScenario === scenario.id

          return (
            <Card
              key={scenario.id}
              className={`${styles.card} ${isSelected ? styles.selected : ''}`}
              onClick={() => onSelect(scenario.id)}
            >
              <CardHeader
                header={<Text weight="semibold">{scenario.name}</Text>}
                description={<Text size={200}>{scenario.description}</Text>}
              />
            </Card>
          )
        })}
      </div>

      <div className={styles.actions}>
        {isAuthenticated && onNavigateToConversations && (
          <Button
            appearance="secondary"
            icon={<History24Regular />}
            onClick={onNavigateToConversations}
          >
            My Practices
          </Button>
        )}
        {isTrainer && onNavigateToAllPractices && (
          <Button
            appearance="secondary"
            icon={<People24Regular />}
            onClick={onNavigateToAllPractices}
          >
            All Practices
          </Button>
        )}
        <div className={styles.avatarSelector}>
          <Label htmlFor="avatar-select">Avatar:</Label>
          <Dropdown
            id="avatar-select"
            className={styles.avatarDropdown}
            value={
              AVATAR_OPTIONS.find(opt => opt.value === selectedAvatar)?.label ||
              ''
            }
            selectedOptions={[selectedAvatar]}
            onOptionSelect={(_, data) => {
              if (data.optionValue) {
                setSelectedAvatar(data.optionValue)
              }
            }}
          >
            {AVATAR_OPTIONS.map(option => (
              <Option key={option.value} value={option.value}>
                {option.label}
              </Option>
            ))}
          </Dropdown>
        </div>
        <Button
          appearance="primary"
          disabled={!selectedScenario}
          onClick={() => onStart(selectedAvatar)}
          size="large"
        >
          Start Training
        </Button>
      </div>
    </>
  )
}
