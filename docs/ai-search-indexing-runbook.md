# AI Search Indexing Runbook

This runbook documents the Azure AI Search indexing implementation for practice support materials and transcripts.

## Target Environment

- Subscription: <your-subscription-id>
- Resource group: <your-resource-group>
- Search service: <your-search-service-name>
- Storage account: <your-storage-account-name>
- Embeddings account: <your-azure-ai-services-account-name>
- Embeddings deployment: text-embedding-3-small

## Provisioned Search Objects

- Indexes:
  - support-materials
  - transcripts
- Data sources:
  - datasource-support-materials
  - datasource-transcripts
- Skillsets:
  - skillset-support-materials
  - skillset-transcripts
- Indexers:
  - support-materials-indexer
  - transcripts-indexer

## Source Data

- support-materials indexer source container: support-materials-src
- transcripts indexer source container: transcripts-src

Current sample load:
- support-materials-src: 3 PDF files
- transcripts-src: 3 TXT files

## Modeling and Chunking

- support-materials:
  - Indexing mode: blob content extraction + enrichment
  - Chunking: Split skill produces page chunks into the chunks field
  - Embeddings: generated from full content into contentVector using text-embedding-3-small
- transcripts:
  - Indexing mode: one search document per transcript file
  - Chunking: no chunk split in v1
  - Embeddings: generated from full transcript text into transcriptVector using text-embedding-3-small

## Operational Notes

- Azure OpenAI local key auth is disabled in this environment.
- Search uses system-assigned managed identity and role assignment to call embeddings.
- Role used: Cognitive Services OpenAI User on the embeddings resource scope.
- Indexers are scheduled every 15 minutes and can be run on demand.

## Validation Checklist

1. Confirm indexes exist.
2. Confirm datasources, skillsets, and indexers exist.
3. Run both indexers and verify last status is success.
4. Verify document counts:
   - support-materials: expected at least 3 docs from current sample set
   - transcripts: expected 3 docs from current sample set
5. Run sample search queries and confirm fields are populated:
   - support-materials: title, sourcePath, chunks
   - transcripts: title, sourcePath, transcriptText

## Future Improvements

- Move support-material embeddings from full-content vectors to per-chunk vectors for finer retrieval grounding.
- Add metadata enrichment fields such as scenarioId, rubricId, and materialType from a preprocessing step.
- Add qualityBand and score metadata to transcript documents during ingestion.
