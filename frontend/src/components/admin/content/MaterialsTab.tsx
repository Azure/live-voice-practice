/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import {
  Button,
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
  Title3,
  makeStyles,
  tokens,
} from '@fluentui/react-components'
import { useRef, useState } from 'react'
import { useAdminMaterials } from '../../../hooks/useAdminContent'

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
  hiddenInput: { display: 'none' },
})

export function MaterialsTab() {
  const styles = useStyles()
  const { items, loading, error, refresh, upload, remove } = useAdminMaterials()
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [uploadError, setUploadError] = useState<string | null>(null)

  const handleUploadClick = () => fileInputRef.current?.click()

  const handleFileChange = async (
    event: React.ChangeEvent<HTMLInputElement>
  ) => {
    const file = event.target.files?.[0]
    event.target.value = ''
    if (!file) return
    setBusy(true)
    setUploadError(null)
    setNotice(null)
    try {
      const result = await upload(file)
      setNotice(
        result.reindexTriggered
          ? `Uploaded ${result.name} and triggered reindex.`
          : `Uploaded ${result.name}. It will be searchable after the next indexer run.`
      )
      await refresh()
    } catch (err) {
      setUploadError(err instanceof Error ? err.message : 'Upload failed')
    } finally {
      setBusy(false)
    }
  }

  const handleDelete = async (name: string) => {
    if (!window.confirm(`Delete support material "${name}"?`)) return
    try {
      await remove(name)
      await refresh()
    } catch (err) {
      window.alert(err instanceof Error ? err.message : 'Delete failed')
    }
  }

  return (
    <div className={styles.root}>
      <div className={styles.header}>
        <div className={styles.headerText}>
          <Title3>Support materials</Title3>
          <Text>
            Reference PDFs indexed for analysis. Uploads are reindexed when
            permitted, otherwise on the next scheduled indexer run.
          </Text>
          <Text size={200}>
            To use a PDF in scoring, reference its exact file name in a
            scenario's Related support materials field. Rubrics use those
            scenario materials when evaluating policy accuracy.
          </Text>
        </div>
        <Button
          appearance="primary"
          disabled={busy}
          onClick={handleUploadClick}
        >
          {busy ? 'Uploading…' : 'Upload PDF'}
        </Button>
        <input
          ref={fileInputRef}
          type="file"
          accept="application/pdf,.pdf"
          className={styles.hiddenInput}
          onChange={handleFileChange}
        />
      </div>

      {notice && (
        <MessageBar intent="success">
          <MessageBarBody>{notice}</MessageBarBody>
        </MessageBar>
      )}
      {(error || uploadError) && (
        <MessageBar intent="error">
          <MessageBarBody>{uploadError ?? error}</MessageBarBody>
        </MessageBar>
      )}

      {loading ? (
        <Spinner label="Loading…" />
      ) : items.length === 0 ? (
        <Text>No support materials yet. Upload a PDF to get started.</Text>
      ) : (
        <Table aria-label="Support materials table">
          <TableHeader>
            <TableRow>
              <TableHeaderCell>File</TableHeaderCell>
              <TableHeaderCell>Actions</TableHeaderCell>
            </TableRow>
          </TableHeader>
          <TableBody>
            {items.map(item => (
              <TableRow key={item.name}>
                <TableCell>{item.name}</TableCell>
                <TableCell>
                  <div className={styles.actions}>
                    <Button
                      size="small"
                      appearance="subtle"
                      onClick={() => handleDelete(item.name)}
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
    </div>
  )
}
