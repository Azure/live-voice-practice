/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useAdminScenarios } from '../../../hooks/useAdminContent'
import { JsonDocumentTab } from './JsonDocumentTab'

const EMPTY_SCENARIO = {
  scenarioId: '',
  title: '',
  scenarioContextIntro: '',
  customerBackground: [],
  conversationGuidelines: [],
  skillsToProbe: [],
  openingLines: [],
  exampleTranscripts: [],
  relatedMaterials: [],
}

export function ScenariosTab() {
  const hook = useAdminScenarios()
  return (
    <JsonDocumentTab
      title="Scenarios"
      description="Customer role-play scenarios used to drive practice conversations."
      idField="scenarioId"
      emptyTemplate={EMPTY_SCENARIO}
      hook={hook}
    />
  )
}
