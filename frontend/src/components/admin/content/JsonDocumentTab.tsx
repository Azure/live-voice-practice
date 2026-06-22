/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Button,
  Dialog,
  DialogActions,
  DialogBody,
  DialogContent,
  DialogSurface,
  DialogTitle,
  Field,
  Input,
  InfoLabel,
  MessageBar,
  MessageBarBody,
  Spinner,
  Table,
  TableBody,
  TableCell,
  TableHeader,
  TableHeaderCell,
  TableRow,
  Text,
  Textarea,
  Title3,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import { useState } from 'react'
import { JsonDoc } from '../../../services/admin'

const useStyles = makeStyles({
  root: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalM,
  },
  header: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'flex-start',
    gap: tokens.spacingHorizontalM,
  },
  headerText: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXXS,
  },
  actions: {
    display: 'flex',
    gap: tokens.spacingHorizontalS,
  },
  dialogContent: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalL,
    maxHeight: 'calc(100vh - 220px)',
    overflowY: 'auto',
    paddingRight: tokens.spacingHorizontalS,
  },
  dialogSurface: {
    width: 'min(960px, calc(100vw - 96px))',
    maxWidth: '960px',
  },
  section: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalM,
    padding: tokens.spacingHorizontalL,
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    borderRadius: tokens.borderRadiusLarge,
    backgroundColor: tokens.colorNeutralBackground1,
  },
  sectionHeader: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXXS,
  },
  sectionTitle: {
    fontWeight: tokens.fontWeightSemibold,
  },
  fullWidth: {
    gridColumn: '1 / -1',
  },
  fieldGrid: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    gap: tokens.spacingHorizontalM,
    '@media (max-width: 720px)': {
      gridTemplateColumns: '1fr',
    },
  },
  textArea: {
    minHeight: '96px',
  },
  compactTextArea: {
    minHeight: '72px',
  },
  rowList: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalS,
  },
  materialRow: {
    display: 'grid',
    gridTemplateColumns: 'minmax(180px, 1fr) minmax(240px, 2fr) auto',
    gap: tokens.spacingHorizontalS,
    alignItems: 'start',
    '@media (max-width: 720px)': {
      gridTemplateColumns: '1fr',
    },
  },
  criteriaRow: {
    display: 'grid',
    gridTemplateColumns: 'minmax(120px, 0.8fr) minmax(160px, 1fr) minmax(260px, 2fr) auto',
    gap: tokens.spacingHorizontalS,
    alignItems: 'start',
    '@media (max-width: 900px)': {
      gridTemplateColumns: '1fr',
    },
  },
  helperText: {
    color: tokens.colorNeutralForeground3,
  },
  dialogActions: {
    borderTop: `1px solid ${tokens.colorNeutralStroke2}`,
    paddingTop: tokens.spacingVerticalM,
  },
})

interface DocumentHook {
  items: JsonDoc[]
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
  create: (doc: JsonDoc) => Promise<JsonDoc>
  update: (id: string, doc: JsonDoc) => Promise<JsonDoc>
  remove: (id: string) => Promise<void>
}

interface Props {
  title: string
  description: string
  idField: string
  emptyTemplate: JsonDoc
  hook: DocumentHook
}

type EditorType = 'scenario' | 'rubric'

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function asStringList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.map(item => String(item)).filter(Boolean)
    : []
}

function linesToList(value: string): string[] {
  return value
    .split('\n')
    .map(item => item.trim())
    .filter(Boolean)
}

function listToLines(value: unknown): string {
  return asStringList(value).join('\n')
}

function asMaterials(value: unknown): JsonDoc[] {
  return Array.isArray(value) ? (value as JsonDoc[]) : []
}

function asCriteria(value: unknown): JsonDoc[] {
  return Array.isArray(value) ? (value as JsonDoc[]) : []
}

function metadataField(doc: JsonDoc, key: string): string {
  const metadata = doc.metadata as Record<string, unknown> | undefined
  const value = metadata?.[key]
  return typeof value === 'string' ? value : '—'
}

export function JsonDocumentTab({
  title,
  description,
  idField,
  emptyTemplate,
  hook,
}: Props) {
  const styles = useStyles()
  const { items, loading, error, refresh, create, update, remove } = hook

  const [dialogOpen, setDialogOpen] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [draftId, setDraftId] = useState('')
  const [draftDoc, setDraftDoc] = useState<JsonDoc>({})
  const [dialogError, setDialogError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const singular = title.replace(/s$/, '')
  const editorType: EditorType =
    idField === 'scenarioId' ? 'scenario' : 'rubric'

  const setDraftField = (key: string, value: unknown) => {
    setDraftDoc(prev => ({ ...prev, [key]: value }))
  }

  const setMaterialField = (
    index: number,
    key: 'document' | 'description',
    value: string
  ) => {
    const materials = asMaterials(draftDoc.relatedMaterials).map(item => ({
      ...item,
    }))
    materials[index] = { ...(materials[index] ?? {}), [key]: value }
    setDraftField('relatedMaterials', materials)
  }

  const removeMaterial = (index: number) => {
    setDraftField(
      'relatedMaterials',
      asMaterials(draftDoc.relatedMaterials).filter((_, i) => i !== index)
    )
  }

  const addMaterial = () => {
    setDraftField('relatedMaterials', [
      ...asMaterials(draftDoc.relatedMaterials),
      { document: '', description: '' },
    ])
  }

  const setCriterionField = (
    index: number,
    key: 'criterionId' | 'name' | 'description',
    value: string
  ) => {
    const criteria = asCriteria(draftDoc.criteria).map(item => ({ ...item }))
    const current = criteria[index] ?? {
      levels: [
        {
          level: 1,
          label: 'Poor',
          description: 'Does not meet expectations.',
        },
        {
          level: 3,
          label: 'Adequate',
          description: 'Partially meets expectations.',
        },
        {
          level: 5,
          label: 'Excellent',
          description: 'Fully meets expectations.',
        },
      ],
    }
    criteria[index] = { ...current, [key]: value }
    setDraftField('criteria', criteria)
  }

  const removeCriterion = (index: number) => {
    setDraftField(
      'criteria',
      asCriteria(draftDoc.criteria).filter((_, i) => i !== index)
    )
  }

  const addCriterion = () => {
    setDraftField('criteria', [
      ...asCriteria(draftDoc.criteria),
      {
        criterionId: '',
        name: '',
        description: '',
        levels: [
          {
            level: 1,
            label: 'Poor',
            description: 'Does not meet expectations.',
          },
          {
            level: 3,
            label: 'Adequate',
            description: 'Partially meets expectations.',
          },
          {
            level: 5,
            label: 'Excellent',
            description: 'Fully meets expectations.',
          },
        ],
      },
    ])
  }

  const openCreate = () => {
    setEditingId(null)
    setDraftId('')
    setDraftDoc({ ...emptyTemplate })
    setDialogError(null)
    setDialogOpen(true)
  }

  const openEdit = (doc: JsonDoc) => {
    const id = String(doc[idField] ?? '')
    setEditingId(id)
    setDraftId(id)
    setDraftDoc({ ...doc })
    setDialogError(null)
    setDialogOpen(true)
  }

  const handleDelete = async (id: string) => {
    if (!window.confirm(`Delete ${singular.toLowerCase()} "${id}"?`)) return
    try {
      await remove(id)
      await refresh()
    } catch (err) {
      window.alert(err instanceof Error ? err.message : 'Delete failed')
    }
  }

  const handleSave = async () => {
    setSaving(true)
    setDialogError(null)
    const parsed: JsonDoc = { ...draftDoc }
    if (editorType === 'scenario') {
      parsed.relatedMaterials = asMaterials(parsed.relatedMaterials).filter(
        material => asString(material.document).trim()
      )
    }
    if (editorType === 'rubric') {
      parsed.criteria = asCriteria(parsed.criteria).filter(
        criterion =>
          asString(criterion.criterionId).trim() ||
          asString(criterion.name).trim() ||
          asString(criterion.description).trim()
      )
    }
    parsed[idField] = draftId.trim()
    if (!parsed[idField]) {
      setDialogError(`'${idField}' is required.`)
      setSaving(false)
      return
    }
    if (editorType === 'scenario' && !parsed.title) {
      setDialogError('Title is required.')
      setSaving(false)
      return
    }
    if (
      editorType === 'rubric' &&
      (!Array.isArray(parsed.criteria) || parsed.criteria.length === 0)
    ) {
      setDialogError('Add at least one criterion.')
      setSaving(false)
      return
    }
    try {
      if (editingId) {
        await update(editingId, parsed)
      } else {
        await create(parsed)
      }
      setDialogOpen(false)
      await refresh()
    } catch (err) {
      setDialogError(err instanceof Error ? err.message : 'Save failed')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className={styles.root}>
      <div className={styles.header}>
        <div className={styles.headerText}>
          <Title3>{title}</Title3>
          <Text>{description}</Text>
        </div>
        <Button appearance="primary" onClick={openCreate}>
          New {singular}
        </Button>
      </div>

      {error && (
        <MessageBar intent="error">
          <MessageBarBody>{error}</MessageBarBody>
        </MessageBar>
      )}

      {loading ? (
        <Spinner label="Loading…" />
      ) : items.length === 0 ? (
        <Text>No {title.toLowerCase()} yet. Create one to get started.</Text>
      ) : (
        <Table aria-label={`${title} table`}>
          <TableHeader>
            <TableRow>
              <TableHeaderCell>ID</TableHeaderCell>
              <TableHeaderCell>Last updated</TableHeaderCell>
              <TableHeaderCell>Updated by</TableHeaderCell>
              <TableHeaderCell>Actions</TableHeaderCell>
            </TableRow>
          </TableHeader>
          <TableBody>
            {items.map(doc => {
              const id = String(doc[idField] ?? '')
              return (
                <TableRow key={id}>
                  <TableCell>{id}</TableCell>
                  <TableCell>{metadataField(doc, 'lastUpdatedAt')}</TableCell>
                  <TableCell>{metadataField(doc, 'lastUpdatedBy')}</TableCell>
                  <TableCell>
                    <div className={styles.actions}>
                      <Button size="small" onClick={() => openEdit(doc)}>
                        Edit
                      </Button>
                      <Button
                        size="small"
                        appearance="subtle"
                        onClick={() => handleDelete(id)}
                      >
                        Delete
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              )
            })}
          </TableBody>
        </Table>
      )}

      <Dialog
        open={dialogOpen}
        onOpenChange={(_, data) => setDialogOpen(data.open)}
      >
        <DialogSurface className={styles.dialogSurface}>
          <DialogBody>
            <DialogTitle>
              {editingId ? `Edit ${editingId}` : `New ${singular}`}
            </DialogTitle>
            <DialogContent className={styles.dialogContent}>
              {dialogError && (
                <MessageBar intent="error">
                  <MessageBarBody>{dialogError}</MessageBarBody>
                </MessageBar>
              )}
              {editorType === 'scenario' ? (
                <>
                  <section className={styles.section}>
                    <div className={styles.sectionHeader}>
                      <Text className={styles.sectionTitle}>Basics</Text>
                      <Text size={200} className={styles.helperText}>
                        Name the scenario and define the first thing the Live
                        Voice Agent says.
                      </Text>
                    </div>
                    <div className={styles.fieldGrid}>
                      <Field label={idField} required>
                        <Input
                          value={draftId}
                          disabled={!!editingId}
                          placeholder="contoso-billing-001"
                          onChange={(_, data) => setDraftId(data.value)}
                        />
                      </Field>
                      <Field
                        label={
                          <InfoLabel info="Short display name shown to trainees when they select a practice scenario.">
                            Title
                          </InfoLabel>
                        }
                        required
                      >
                        <Input
                          value={asString(draftDoc.title)}
                          placeholder="Frustrated Customer with Billing Charge"
                          onChange={(_, data) =>
                            setDraftField('title', data.value)
                          }
                        />
                      </Field>
                      <Field
                        className={styles.fullWidth}
                        label={
                          <InfoLabel info="One opening line the Live Voice Agent can say at the start of the call.">
                            Opening line
                          </InfoLabel>
                        }
                      >
                        <Input
                          value={asStringList(draftDoc.openingLines)[0] ?? ''}
                          placeholder="Hi, I am calling about a charge on my bill."
                          onChange={(_, data) =>
                            setDraftField('openingLines', [data.value])
                          }
                        />
                      </Field>
                    </div>
                  </section>

                  <section className={styles.section}>
                    <div className={styles.sectionHeader}>
                      <Text className={styles.sectionTitle}>
                        Customer role and behavior
                      </Text>
                      <Text size={200} className={styles.helperText}>
                        These fields tell the Live Voice Agent who to play and
                        how to behave during the call.
                      </Text>
                    </div>
                    <Field
                      label={
                        <InfoLabel info="Tell the Live Voice Agent who they are and why they are calling. This is not shown as JSON.">
                          Scenario context
                        </InfoLabel>
                      }
                    >
                      <Textarea
                        className={styles.textArea}
                        resize="vertical"
                        value={asString(draftDoc.scenarioContextIntro)}
                        placeholder="You are a frustrated customer calling about an unresolved billing charge."
                        onChange={(_, data) =>
                          setDraftField('scenarioContextIntro', data.value)
                        }
                      />
                    </Field>
                    <div className={styles.fieldGrid}>
                      <Field
                        label={
                          <InfoLabel info="One background fact per line. These guide the Live Voice Agent during the conversation.">
                            Customer background
                          </InfoLabel>
                        }
                      >
                        <Textarea
                          className={styles.textArea}
                          resize="vertical"
                          value={listToLines(draftDoc.customerBackground)}
                          placeholder={
                            'You have been a customer for several years.\nYou were charged incorrectly on your most recent bill.'
                          }
                          onChange={(_, data) =>
                            setDraftField(
                              'customerBackground',
                              linesToList(data.value)
                            )
                          }
                        />
                      </Field>
                      <Field
                        label={
                          <InfoLabel info="One behavior guideline per line. Use these to make the Live Voice Agent act naturally.">
                            Conversation guidelines
                          </InfoLabel>
                        }
                      >
                        <Textarea
                          className={styles.textArea}
                          resize="vertical"
                          value={listToLines(draftDoc.conversationGuidelines)}
                          placeholder={
                            'Speak naturally, as a real customer would.\nAsk follow-up questions if something is unclear.'
                          }
                          onChange={(_, data) =>
                            setDraftField(
                              'conversationGuidelines',
                              linesToList(data.value)
                            )
                          }
                        />
                      </Field>
                    </div>
                  </section>

                  <section className={styles.section}>
                    <div className={styles.sectionHeader}>
                      <Text className={styles.sectionTitle}>
                        Evaluation context
                      </Text>
                      <Text size={200} className={styles.helperText}>
                        Link this scenario to skills, support files, and sample
                        transcripts used during evaluation.
                      </Text>
                    </div>
                    <div className={styles.fieldGrid}>
                      <Field
                        label={
                          <InfoLabel info="One skill per line. Rubrics can score these explicitly.">
                            Skills to probe
                          </InfoLabel>
                        }
                      >
                        <Textarea
                          className={styles.compactTextArea}
                          resize="vertical"
                          value={listToLines(draftDoc.skillsToProbe)}
                          placeholder={
                            'Shows empathy and professionalism\nExplains steps clearly'
                          }
                          onChange={(_, data) =>
                            setDraftField(
                              'skillsToProbe',
                              linesToList(data.value)
                            )
                          }
                        />
                      </Field>
                      <Field
                        label={
                          <InfoLabel info="Optional transcript IDs, one per line. Add transcripts in the Transcripts tab first.">
                            Example transcripts
                          </InfoLabel>
                        }
                      >
                        <Textarea
                          className={styles.compactTextArea}
                          resize="vertical"
                          value={listToLines(draftDoc.exampleTranscripts)}
                          placeholder={'transcript-001\ntranscript-002'}
                          onChange={(_, data) =>
                            setDraftField(
                              'exampleTranscripts',
                              linesToList(data.value)
                            )
                          }
                        />
                      </Field>
                      <Field
                        className={styles.fullWidth}
                        label={
                          <InfoLabel info="Reference uploaded support material files by exact file name. The evaluator uses these when checking policy accuracy.">
                            Related support materials
                          </InfoLabel>
                        }
                      >
                        <div className={styles.rowList}>
                          {asMaterials(draftDoc.relatedMaterials).map(
                            (material, index) => (
                              <div
                                className={styles.materialRow}
                                key={`material-${index}`}
                              >
                                <Input
                                  value={asString(material.document)}
                                  placeholder="contoso_billing.pdf"
                                  aria-label="Support material file name"
                                  onChange={(_, data) =>
                                    setMaterialField(
                                      index,
                                      'document',
                                      data.value
                                    )
                                  }
                                />
                                <Input
                                  value={asString(material.description)}
                                  placeholder="Billing and refund policy"
                                  aria-label="Support material description"
                                  onChange={(_, data) =>
                                    setMaterialField(
                                      index,
                                      'description',
                                      data.value
                                    )
                                  }
                                />
                                <Button
                                  appearance="subtle"
                                  onClick={() => removeMaterial(index)}
                                >
                                  Remove
                                </Button>
                              </div>
                            )
                          )}
                          <Button appearance="secondary" onClick={addMaterial}>
                            Add support material
                          </Button>
                        </div>
                      </Field>
                    </div>
                  </section>
                </>
              ) : (
                <>
                  <section className={styles.section}>
                    <div className={styles.sectionHeader}>
                      <Text className={styles.sectionTitle}>Basics</Text>
                      <Text size={200} className={styles.helperText}>
                        Connect the rubric to one or more scenarios.
                      </Text>
                    </div>
                    <div className={styles.fieldGrid}>
                      <Field label={idField} required>
                        <Input
                          value={draftId}
                          disabled={!!editingId}
                          placeholder="contoso-rubric-billing-v1"
                          onChange={(_, data) => setDraftId(data.value)}
                        />
                      </Field>
                      <Field
                        label={
                          <InfoLabel info="Scenario IDs this rubric applies to, one per line. These must match scenario IDs in the Scenarios tab.">
                            Scenario IDs
                          </InfoLabel>
                        }
                      >
                        <Textarea
                          className={styles.compactTextArea}
                          resize="vertical"
                          value={listToLines(
                            (draftDoc.appliesTo as JsonDoc | undefined)
                              ?.scenarioIds
                          )}
                          placeholder={'contoso-billing-001\ncontoso-support-002'}
                          onChange={(_, data) =>
                            setDraftField('appliesTo', {
                              scenarioIds: linesToList(data.value),
                            })
                          }
                        />
                      </Field>
                    </div>
                  </section>

                  <section className={styles.section}>
                    <div className={styles.sectionHeader}>
                      <Text className={styles.sectionTitle}>
                        Scoring criteria
                      </Text>
                      <Text size={200} className={styles.helperText}>
                        Add each criterion as its own row. The default 1, 3,
                        and 5 scoring levels are created automatically.
                      </Text>
                    </div>
                    <Field
                      label={
                        <InfoLabel info="Each row needs a stable ID, a short display name, and a description of what good performance means.">
                          Criteria
                        </InfoLabel>
                      }
                      required
                    >
                      <div className={styles.rowList}>
                        {asCriteria(draftDoc.criteria).map(
                          (criterion, index) => (
                            <div
                              className={styles.criteriaRow}
                              key={`criterion-${index}`}
                            >
                              <Input
                                value={asString(criterion.criterionId)}
                                placeholder="empathy"
                                aria-label="Criterion ID"
                                onChange={(_, data) =>
                                  setCriterionField(
                                    index,
                                    'criterionId',
                                    data.value
                                  )
                                }
                              />
                              <Input
                                value={asString(criterion.name)}
                                placeholder="Empathy"
                                aria-label="Criterion display name"
                                onChange={(_, data) =>
                                  setCriterionField(index, 'name', data.value)
                                }
                              />
                              <Textarea
                                className={styles.compactTextArea}
                                resize="vertical"
                                value={asString(criterion.description)}
                                placeholder="Shows empathy and professionalism."
                                aria-label="Criterion description"
                                onChange={(_, data) =>
                                  setCriterionField(
                                    index,
                                    'description',
                                    data.value
                                  )
                                }
                              />
                              <Button
                                appearance="subtle"
                                onClick={() => removeCriterion(index)}
                              >
                                Remove
                              </Button>
                            </div>
                          )
                        )}
                        <Button appearance="secondary" onClick={addCriterion}>
                          Add criterion
                        </Button>
                      </div>
                    </Field>
                  </section>

                  <section className={styles.section}>
                    <div className={styles.sectionHeader}>
                      <Text className={styles.sectionTitle}>
                        Pass rules and references
                      </Text>
                      <Text size={200} className={styles.helperText}>
                        Define the pass mark and optional transcript examples
                        used as scoring references.
                      </Text>
                    </div>
                    <div className={styles.fieldGrid}>
                      <Field
                        label={
                          <InfoLabel info="Score range used by all criteria. Keep 1-5 unless your rubric intentionally uses another scale.">
                            Scale
                          </InfoLabel>
                        }
                      >
                        <Input
                          value={
                            asString(
                              (draftDoc.scoring as JsonDoc | undefined)?.scale
                            ) || '1-5'
                          }
                          onChange={(_, data) =>
                            setDraftField('scoring', {
                              ...(draftDoc.scoring as JsonDoc | undefined),
                              scale: data.value,
                            })
                          }
                        />
                      </Field>
                      <Field
                        label={
                          <InfoLabel info="Minimum average score needed to pass. Example: 3.5 on a 1-5 scale.">
                            Pass threshold
                          </InfoLabel>
                        }
                      >
                        <Input
                          type="number"
                          value={String(
                            (draftDoc.scoring as JsonDoc | undefined)
                              ?.passThreshold ?? 3.5
                          )}
                          onChange={(_, data) =>
                            setDraftField('scoring', {
                              ...(draftDoc.scoring as JsonDoc | undefined),
                              passThreshold: Number(data.value),
                              overallScoreMethod:
                                (draftDoc.scoring as JsonDoc | undefined)
                                  ?.overallScoreMethod ?? 'average',
                            })
                          }
                        />
                      </Field>
                      <Field
                        className={styles.fullWidth}
                        label={
                          <InfoLabel info="Optional transcript IDs used as references, one per line. Add transcripts in the Transcripts tab first.">
                            Reference transcripts
                          </InfoLabel>
                        }
                      >
                        <Textarea
                          className={styles.compactTextArea}
                          resize="vertical"
                          value={listToLines(draftDoc.referenceTranscripts)}
                          placeholder={'transcript-001\ntranscript-002'}
                          onChange={(_, data) =>
                            setDraftField(
                              'referenceTranscripts',
                              linesToList(data.value)
                            )
                          }
                        />
                      </Field>
                    </div>
                  </section>
                </>
              )}
              <Text size={200} className={styles.helperText}>
                We'll save this in the right format automatically.
              </Text>
            </DialogContent>
            <DialogActions className={styles.dialogActions}>
              <Button
                appearance="secondary"
                onClick={() => setDialogOpen(false)}
              >
                Cancel
              </Button>
              <Button
                appearance="primary"
                disabled={saving}
                onClick={handleSave}
              >
                {saving
                  ? 'Saving…'
                  : editorType === 'scenario'
                    ? 'Save scenario'
                    : 'Save rubric'}
              </Button>
            </DialogActions>
          </DialogBody>
        </DialogSurface>
      </Dialog>
    </div>
  )
}
