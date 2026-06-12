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
import { useAdminTranscripts } from '../../../hooks/useAdminContent'

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
  actions: { display: 'flex', gap: tokens.spacingHorizontalS },
  dialogContent: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalM,
  },
})

export function TranscriptsTab() {
  const styles = useStyles()
  const { items, loading, error, refresh, get, create, update, remove } =
    useAdminTranscripts()

  const [dialogOpen, setDialogOpen] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [draftId, setDraftId] = useState('')
  const [draftText, setDraftText] = useState('')
  const [dialogError, setDialogError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const openCreate = () => {
    setEditingId(null)
    setDraftId('')
    setDraftText('')
    setDialogError(null)
    setDialogOpen(true)
  }

  const openEdit = async (id: string) => {
    setEditingId(id)
    setDraftId(id)
    setDraftText('')
    setDialogError(null)
    setDialogOpen(true)
    try {
      const doc = await get(id)
      setDraftText(doc.text)
    } catch (err) {
      setDialogError(err instanceof Error ? err.message : 'Failed to load')
    }
  }

  const handleDelete = async (id: string) => {
    if (!window.confirm(`Delete transcript "${id}"?`)) return
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
    const id = draftId.trim()
    if (!id) {
      setDialogError('Transcript id is required.')
      setSaving(false)
      return
    }
    try {
      if (editingId) {
        await update(editingId, draftText)
      } else {
        await create(id, draftText)
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
          <Title3>Transcripts</Title3>
          <Text>
            Example conversation transcripts referenced by scenarios and
            rubrics.
          </Text>
        </div>
        <Button appearance="primary" onClick={openCreate}>
          New transcript
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
        <Text>No transcripts yet. Create one to get started.</Text>
      ) : (
        <Table aria-label="Transcripts table">
          <TableHeader>
            <TableRow>
              <TableHeaderCell>Transcript ID</TableHeaderCell>
              <TableHeaderCell>Actions</TableHeaderCell>
            </TableRow>
          </TableHeader>
          <TableBody>
            {items.map(id => (
              <TableRow key={id}>
                <TableCell>{id}</TableCell>
                <TableCell>
                  <div className={styles.actions}>
                    <Button size="small" onClick={() => openEdit(id)}>
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
            ))}
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
              {editingId ? `Edit ${editingId}` : 'New transcript'}
            </DialogTitle>
            <DialogContent className={styles.dialogContent}>
              {dialogError && (
                <MessageBar intent="error">
                  <MessageBarBody>{dialogError}</MessageBarBody>
                </MessageBar>
              )}
              <Field label="Transcript ID" required>
                <Input
                  value={draftId}
                  disabled={!!editingId}
                  placeholder="transcript-004"
                  onChange={(_, data) => setDraftId(data.value)}
                />
              </Field>
              <Field label="Transcript text" required>
                <Textarea
                  resize="vertical"
                  rows={16}
                  value={draftText}
                  onChange={(_, data) => setDraftText(data.value)}
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
