# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Support-materials service: PDF blob storage + best-effort AI Search reindex.

PDFs live in the ``support-materials-src`` blob container that the AI Search
indexer reads from. Uploading/deleting blobs works with the container app's
``Storage Blob Data Contributor`` role. Triggering the indexer requires
``Search Service Contributor``; when that role is absent the upload still
succeeds and the document becomes searchable on the next scheduled indexer
run. The reindex outcome is reported back to the caller rather than failing
the upload.
"""

import logging
from typing import Any, Dict, List, Optional

from azure.identity import DefaultAzureCredential

from src.config import config
from src.services.blob_repository import BlobRepository

logger = logging.getLogger(__name__)

PDF_CONTENT_TYPE = "application/pdf"


class MaterialsService:
    """Manages support-material PDFs in Blob Storage and AI Search reindexing."""

    def __init__(self) -> None:
        self._blobs = BlobRepository(config.get("materials_storage_container", "support-materials-src"))

    def list_materials(self) -> List[Dict[str, Any]]:
        """List support-material documents (by blob name)."""
        return [{"name": name} for name in sorted(self._blobs.list_names())]

    def upload_material(self, blob_name: str, data: bytes) -> Dict[str, Any]:
        """Upload a PDF and best-effort trigger a reindex.

        Returns a dict describing the uploaded blob and whether reindexing was
        successfully triggered.
        """
        if not blob_name or not blob_name.strip():
            raise ValueError("Material file name is required")
        if not data:
            raise ValueError("Material file is empty")
        self._blobs.upload_bytes(blob_name, data, content_type=PDF_CONTENT_TYPE)
        reindexed = self._trigger_reindex()
        return {"name": blob_name, "reindexTriggered": reindexed}

    def delete_material(self, blob_name: str) -> Dict[str, Any]:
        """Delete a PDF blob and best-effort trigger a reindex."""
        deleted = self._blobs.delete(blob_name)
        reindexed = self._trigger_reindex() if deleted else False
        return {"name": blob_name, "deleted": deleted, "reindexTriggered": reindexed}

    def _trigger_reindex(self) -> bool:
        """Best-effort: run the AI Search indexer. Returns ``False`` on any failure."""
        endpoint = config.get("azure_search_endpoint", "") or config.get("search_service_endpoint", "")
        indexer_name = config.get("azure_search_indexer", "")
        if not endpoint or not indexer_name:
            logger.info("Search endpoint/indexer not configured; skipping reindex trigger")
            return False
        try:
            from azure.search.documents.indexes import SearchIndexerClient  # local import

            client = SearchIndexerClient(endpoint=endpoint, credential=DefaultAzureCredential())
            client.run_indexer(indexer_name)
            logger.info("Triggered AI Search indexer '%s'", indexer_name)
            return True
        except Exception as exc:  # noqa: BLE001 - reindex is non-critical
            logger.warning("Could not trigger AI Search indexer (non-blocking): %s", exc)
            return False


# Singleton instance used by the admin routes.
materials_service: Optional[MaterialsService] = MaterialsService()
