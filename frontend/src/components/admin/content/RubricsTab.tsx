/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { useAdminRubrics } from '../../../hooks/useAdminContent'
import { JsonDocumentTab } from './JsonDocumentTab'

const EMPTY_RUBRIC = {
  rubricId: '',
  appliesTo: { scenarioIds: [] },
  referenceTranscripts: [],
  criteria: [
    {
      criterionId: '',
      name: '',
      description: '',
      levels: [
        { level: 1, label: 'Poor', description: '' },
        { level: 3, label: 'Adequate', description: '' },
        { level: 5, label: 'Excellent', description: '' },
      ],
    },
  ],
  scoring: { scale: '1-5', overallScoreMethod: 'average', passThreshold: 3.5 },
}

export function RubricsTab() {
  const hook = useAdminRubrics()
  return (
    <JsonDocumentTab
      title="Rubrics"
      description="Evaluation rubrics. appliesTo.scenarioIds must reference existing scenarios."
      idField="rubricId"
      emptyTemplate={EMPTY_RUBRIC}
      hook={hook}
    />
  )
}
