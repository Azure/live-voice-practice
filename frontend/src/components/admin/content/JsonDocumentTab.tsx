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
  jsonArea: {
    fontFamily: 'monospace',
  },
  dialogContent: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalM,
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
  const [draftJson, setDraftJson] = useState('')
  const [dialogError, setDialogError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const singular = title.replace(/s$/, '')

  const openCreate = () => {
    setEditingId(null)
    setDraftId('')
    setDraftJson(JSON.stringify(emptyTemplate, null, 2))
    setDialogError(null)
    setDialogOpen(true)
  }

  const openEdit = (doc: JsonDoc) => {
    const id = String(doc[idField] ?? '')
    setEditingId(id)
    setDraftId(id)
    setDraftJson(JSON.stringify(doc, null, 2))
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
    let parsed: JsonDoc
    try {
      parsed = JSON.parse(draftJson) as JsonDoc
    } catch {
      setDialogError('Invalid JSON — please fix the syntax before saving.')
      setSaving(false)
      return
    }
    if (draftId.trim()) {
      parsed[idField] = draftId.trim()
    }
    if (!parsed[idField]) {
      setDialogError(`'${idField}' is required.`)
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
                  onChange={(_, data) => setDraftId(data.value)}
                />
              </Field>
              <Field
                label="Document (JSON)"
                hint="The raw document is validated on save."
              >
                <Textarea
                  className={styles.jsonArea}
                  resize="vertical"
                  rows={18}
                  value={draftJson}
                  onChange={(_, data) => setDraftJson(data.value)}
                />
              </Field>
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
