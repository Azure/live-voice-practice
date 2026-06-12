# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Generic Azure Blob Storage repository for admin-managed content.

Used by transcripts (text blobs in the ``transcripts`` container) and support
materials (PDF blobs in the ``documents`` container). Authentication is via
``DefaultAzureCredential`` (the container app's managed identity holds the
``Storage Blob Data Contributor`` role).
"""

import logging
from typing import List, Optional

from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

from src.config import config

logger = logging.getLogger(__name__)


class BlobRepositoryError(RuntimeError):
    """Raised when blob storage is not configured or unreachable."""


class BlobRepository:
    """CRUD helper for blobs within a single storage container."""

    def __init__(self, container_name: str):
        """Initialize the repository for a given blob container name."""
        self.container_name = container_name
        self._service: Optional[BlobServiceClient] = None
        self._initialized = False

    def _ensure_service(self) -> BlobServiceClient:
        """Lazily build the BlobServiceClient; raise if storage is not configured."""
        if self._initialized:
            if self._service is None:
                raise BlobRepositoryError("Blob storage is not configured")
            return self._service

        self._initialized = True
        endpoint = config.get("storage_blob_endpoint", "")
        if not endpoint:
            logger.warning("storage_blob_endpoint not configured; %s blob repository disabled", self.container_name)
            raise BlobRepositoryError("Blob storage is not configured")

        self._service = BlobServiceClient(account_url=endpoint, credential=DefaultAzureCredential())
        logger.info("BlobRepository ready: %s/%s", endpoint, self.container_name)
        return self._service

    def list_names(self, prefix: str = "") -> List[str]:
        """List blob names in the container, optionally filtered by prefix."""
        service = self._ensure_service()
        container = service.get_container_client(self.container_name)
        return [blob.name for blob in container.list_blobs(name_starts_with=prefix or None)]

    def exists(self, blob_name: str) -> bool:
        """Return whether a blob with the given name exists."""
        service = self._ensure_service()
        return service.get_blob_client(self.container_name, blob_name).exists()

    def get_text(self, blob_name: str) -> Optional[str]:
        """Download a blob's content decoded as UTF-8 text, or ``None`` if missing."""
        service = self._ensure_service()
        blob = service.get_blob_client(self.container_name, blob_name)
        try:
            data = blob.download_blob().readall()
        except ResourceNotFoundError:
            return None
        return data.decode("utf-8")

    def upload_text(self, blob_name: str, text: str) -> None:
        """Upload UTF-8 text to a blob, overwriting any existing content."""
        self.upload_bytes(blob_name, text.encode("utf-8"), content_type="text/plain")

    def upload_bytes(self, blob_name: str, data: bytes, content_type: Optional[str] = None) -> None:
        """Upload raw bytes to a blob, overwriting any existing content."""
        from azure.storage.blob import ContentSettings  # local import keeps module load light

        service = self._ensure_service()
        blob = service.get_blob_client(self.container_name, blob_name)
        content_settings = ContentSettings(content_type=content_type) if content_type else None
        blob.upload_blob(data, overwrite=True, content_settings=content_settings)

    def delete(self, blob_name: str) -> bool:
        """Delete a blob by name. Returns ``False`` if it did not exist."""
        service = self._ensure_service()
        blob = service.get_blob_client(self.container_name, blob_name)
        try:
            blob.delete_blob()
            return True
        except ResourceNotFoundError:
            return False
