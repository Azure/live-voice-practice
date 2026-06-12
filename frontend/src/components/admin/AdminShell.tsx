/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Link as FluentLink,
  Spinner,
  Tab,
  TabList,
  Text,
  Title3,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import { useState } from 'react'
import { Route, Routes, useNavigate } from 'react-router-dom'
import { useAuth } from '../../hooks/useAuth'
import { UserHeader } from '../UserHeader'
import { StatisticsTab } from './StatisticsTab'
import { TraineeDetail } from './TraineeDetail'
import { ScenariosTab } from './content/ScenariosTab'
import { RubricsTab } from './content/RubricsTab'
import { TranscriptsTab } from './content/TranscriptsTab'
import { MaterialsTab } from './content/MaterialsTab'

const useStyles = makeStyles({
  root: {
    minHeight: '100vh',
    backgroundColor: tokens.colorNeutralBackground3,
    padding: tokens.spacingVerticalXL,
    boxSizing: 'border-box',
  },
  header: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
    marginBottom: tokens.spacingVerticalL,
  },
  content: {
    backgroundColor: tokens.colorNeutralBackground1,
    borderRadius: tokens.borderRadiusLarge,
    padding: tokens.spacingVerticalL,
    boxShadow: tokens.shadow4,
  },
  centered: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: tokens.spacingVerticalM,
    minHeight: '60vh',
    textAlign: 'center',
  },
})

type AdminTab =
  | 'statistics'
  | 'scenarios'
  | 'rubrics'
  | 'transcripts'
  | 'materials'

export function AdminShell() {
  const styles = useStyles()
  const navigate = useNavigate()
  const { authenticated, user, isTrainer, loading } = useAuth()
  const [selectedTab, setSelectedTab] = useState<AdminTab>('statistics')

  if (loading) {
    return (
      <div className={styles.root}>
        <div className={styles.centered}>
          <Spinner label="Loading…" />
        </div>
      </div>
    )
  }

  if (!authenticated || !isTrainer) {
    return (
      <div className={styles.root}>
        <div className={styles.centered}>
          <Title3>Access denied</Title3>
          <Text>You need the trainer role to view this page.</Text>
          <FluentLink onClick={() => navigate('/')}>Back to app</FluentLink>
        </div>
      </div>
    )
  }

  return (
    <div className={styles.root}>
      <UserHeader
        userName={user?.name}
        authenticated={authenticated}
        role={user?.role}
        isTrainer={isTrainer}
      />
      <Routes>
        <Route path="statistics/trainees/:id" element={<TraineeDetail />} />
        <Route
          path="*"
          element={
            <>
              <div className={styles.header}>
                <Title3>Admin</Title3>
                <FluentLink onClick={() => navigate('/')}>
                  Back to app
                </FluentLink>
              </div>
              <TabList
                selectedValue={selectedTab}
                onTabSelect={(_, data) =>
                  setSelectedTab(data.value as AdminTab)
                }
              >
                <Tab value="statistics">Statistics</Tab>
                <Tab value="scenarios">Scenarios</Tab>
                <Tab value="rubrics">Rubrics</Tab>
                <Tab value="transcripts">Transcripts</Tab>
                <Tab value="materials">Support materials</Tab>
              </TabList>
              <div className={styles.content}>
                {selectedTab === 'statistics' && <StatisticsTab />}
                {selectedTab === 'scenarios' && <ScenariosTab />}
                {selectedTab === 'rubrics' && <RubricsTab />}
                {selectedTab === 'transcripts' && <TranscriptsTab />}
                {selectedTab === 'materials' && <MaterialsTab />}
              </div>
            </>
          }
        />
      </Routes>
    </div>
  )
}
