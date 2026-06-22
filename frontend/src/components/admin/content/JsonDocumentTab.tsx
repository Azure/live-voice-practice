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
    gap: tokens.spacingVerticalM,
  },
  fieldGrid: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    gap: tokens.spacingHorizontalM,
    '@media (max-width: 720px)': {
      gridTemplateColumns: '1fr',
    },
  },
  helperText: {
    color: tokens.colorNeutralForeground3,
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

function materialLinesToList(value: string): JsonDoc[] {
  return value
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      const [document, ...descriptionParts] = line.split('|')
      return {
        document: document.trim(),
        description: descriptionParts.join('|').trim(),
      }
    })
}

function materialListToLines(value: unknown): string {
  if (!Array.isArray(value)) return ''
  return value
    .map(item => {
      if (!item || typeof item !== 'object') return ''
      const material = item as Record<string, unknown>
      const document = asString(material.document)
      const description = asString(material.description)
      return description ? `${document} | ${description}` : document
    })
    .filter(Boolean)
    .join('\n')
}

function parseRubricCriteria(value: string): JsonDoc[] {
  return value
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      const [criterionId, name, description] = line
        .split('|')
        .map(part => part.trim())
      return {
        criterionId,
        name: name || criterionId,
        description: description || '',
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
    })
}

function rubricCriteriaToLines(value: unknown): string {
  if (!Array.isArray(value)) return ''
  return value
    .map(item => {
      if (!item || typeof item !== 'object') return ''
      const criterion = item as Record<string, unknown>
      return [
        asString(criterion.criterionId),
        asString(criterion.name),
        asString(criterion.description),
      ].join(' | ')
    })
    .filter(Boolean)
    .join('\n')
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
        <DialogSurface>
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
              <Field label={idField} required>
                <Input
                  value={draftId}
                  disabled={!!editingId}
                  placeholder={
                    editorType === 'scenario'
                      ? 'contoso-billing-001'
                      : 'contoso-rubric-billing-v1'
                  }
                  onChange={(_, data) => setDraftId(data.value)}
                />
              </Field>
              {editorType === 'scenario' ? (
                <>
                  <div className={styles.fieldGrid}>
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
                      label={
                        <InfoLabel info="One opening line the avatar can say at the start of the call.">
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
                  <Field
                    label={
                      <InfoLabel info="Tell the avatar who they are and why they are calling. This is not shown as JSON.">
                        Scenario context
                      </InfoLabel>
                    }
                  >
                    <Textarea
                      resize="vertical"
                      rows={3}
                      value={asString(draftDoc.scenarioContextIntro)}
                      placeholder="You are a frustrated customer calling about an unresolved billing charge."
                      onChange={(_, data) =>
                        setDraftField('scenarioContextIntro', data.value)
                      }
                    />
                  </Field>
                  <Field
                    label={
                      <InfoLabel info="One background fact per line. These guide the customer avatar during the conversation.">
                        Customer background
                      </InfoLabel>
                    }
                  >
                    <Textarea
                      resize="vertical"
                      rows={4}
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
                      <InfoLabel info="One behavior guideline per line. Use these to make the avatar act naturally.">
                        Conversation guidelines
                      </InfoLabel>
                    }
                  >
                    <Textarea
                      resize="vertical"
                      rows={4}
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
                  <Field
                    label={
                      <InfoLabel info="One skill per line. Rubrics can score these explicitly.">
                        Skills to probe
                      </InfoLabel>
                    }
                  >
                    <Textarea
                      resize="vertical"
                      rows={3}
                      value={listToLines(draftDoc.skillsToProbe)}
                      placeholder={
                        'Shows empathy and professionalism\nExplains steps clearly'
                      }
                      onChange={(_, data) =>
                        setDraftField('skillsToProbe', linesToList(data.value))
                      }
                    />
                  </Field>
                  <Field
                    label={
                      <InfoLabel info="Reference uploaded support material files by exact file name. Format: file.pdf | optional description. The evaluator uses these when checking policy accuracy.">
                        Related support materials
                      </InfoLabel>
                    }
                  >
                    <Textarea
                      resize="vertical"
                      rows={3}
                      value={materialListToLines(draftDoc.relatedMaterials)}
                      placeholder={
                        'contoso_billing.pdf | Contoso Billing and Refund Policy\ncontoso_support_tone_guide.pdf | Support tone guidelines'
                      }
                      onChange={(_, data) =>
                        setDraftField(
                          'relatedMaterials',
                          materialLinesToList(data.value)
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
                      resize="vertical"
                      rows={2}
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
                </>
              ) : (
                <>
                  <Field
                    label={
                      <InfoLabel info="Scenario IDs this rubric applies to, one per line. These must match scenario IDs in the Scenarios tab.">
                        Scenario IDs
                      </InfoLabel>
                    }
                  >
                    <Textarea
                      resize="vertical"
                      rows={3}
                      value={listToLines(
                        (draftDoc.appliesTo as JsonDoc | undefined)?.scenarioIds
                      )}
                      placeholder={'contoso-billing-001\ncontoso-support-002'}
                      onChange={(_, data) =>
                        setDraftField('appliesTo', {
                          scenarioIds: linesToList(data.value),
                        })
                      }
                    />
                  </Field>
                  <Field
                    label={
                      <InfoLabel info="One criterion per line using: id | display name | description. The app creates the rubric JSON and default 1, 3, 5 scoring levels automatically.">
                        Criteria
                      </InfoLabel>
                    }
                    required
                  >
                    <Textarea
                      resize="vertical"
                      rows={6}
                      value={rubricCriteriaToLines(draftDoc.criteria)}
                      placeholder={
                        'empathy | Empathy | Shows empathy and professionalism.\nclarity | Clarity | Explains next steps clearly.'
                      }
                      onChange={(_, data) =>
                        setDraftField(
                          'criteria',
                          parseRubricCriteria(data.value)
                        )
                      }
                    />
                  </Field>
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
                  </div>
                  <Field
                    label={
                      <InfoLabel info="Optional transcript IDs used as references, one per line. Add transcripts in the Transcripts tab first.">
                        Reference transcripts
                      </InfoLabel>
                    }
                  >
                    <Textarea
                      resize="vertical"
                      rows={2}
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
                </>
              )}
              <Text size={200} className={styles.helperText}>
                The app stores this as the required JSON document automatically.
              </Text>
            </DialogContent>
            <DialogActions>
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
                {saving ? 'Saving…' : 'Save'}
              </Button>
            </DialogActions>
          </DialogBody>
        </DialogSurface>
      </Dialog>
    </div>
  )
}
