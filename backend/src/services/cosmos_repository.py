# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Generic Cosmos DB document repository for admin content CRUD.

This keeps the admin content service free of low-level Cosmos plumbing and is
reused for every container whose ``id`` field equals its partition key value
(e.g. ``scenarios`` keyed by ``scenarioId`` and ``rubrics`` keyed by
``rubricId``). The seed script (``scripts/seed_cosmos_samples.py``) stamps
``id == <idField>`` so point reads/deletes use the resource id as both the
item id and the partition key.
"""

import logging
from typing import Any, Dict, List, Optional

from azure.cosmos import CosmosClient, exceptions
from azure.identity import DefaultAzureCredential

from src.config import config

logger = logging.getLogger(__name__)


class CosmosRepositoryError(RuntimeError):
    """Raised when the repository cannot service a request (config/connectivity)."""


class CosmosRepository:
    """CRUD helper for a single Cosmos container keyed by ``id_field``."""

    def __init__(self, container_name: str, id_field: str):
        """Initialize the repository.

        Args:
            container_name: Name of the Cosmos container.
            id_field: Document field whose value is used as both the Cosmos
                ``id`` and the partition key value.
        """
        self.container_name = container_name
        self.id_field = id_field
        self._client: Optional[CosmosClient] = None
        self._container: Any = None
        self._initialized = False

    def _ensure_container(self) -> Any:
        """Lazily build the container client; raise if Cosmos is not configured."""
        if self._initialized:
            if self._container is None:
                raise CosmosRepositoryError("Cosmos DB is not configured")
            return self._container

        self._initialized = True
        endpoint = config.get("cosmos_endpoint", "")
        database_name = config.get("cosmos_database_name", "")
        if not endpoint or not database_name:
            logger.warning("Cosmos endpoint/database not configured; %s repository disabled", self.container_name)
            raise CosmosRepositoryError("Cosmos DB is not configured")

        self._client = CosmosClient(endpoint, credential=DefaultAzureCredential())
        database = self._client.get_database_client(database_name)
        self._container = database.get_container_client(self.container_name)
        logger.info("CosmosRepository ready: %s/%s", database_name, self.container_name)
        return self._container

    def list_all(self) -> List[Dict[str, Any]]:
        """Return every document in the container (raw Cosmos shape)."""
        container = self._ensure_container()
        return list(container.read_all_items())

    def get(self, resource_id: str) -> Optional[Dict[str, Any]]:
        """Return a single document by id, or ``None`` if it does not exist."""
        container = self._ensure_container()
        try:
            return container.read_item(item=resource_id, partition_key=resource_id)
        except exceptions.CosmosResourceNotFoundError:
            return None

    def exists(self, resource_id: str) -> bool:
        """Return whether a document with the given id exists."""
        return self.get(resource_id) is not None

    def upsert(self, document: Dict[str, Any]) -> Dict[str, Any]:
        """Create or replace a document, normalizing ``id`` to ``id_field``."""
        container = self._ensure_container()
        resource_id = str(document.get(self.id_field) or "")
        if not resource_id:
            raise CosmosRepositoryError(f"Document missing required '{self.id_field}'")
        normalized = dict(document)
        normalized["id"] = resource_id
        return container.upsert_item(normalized)

    def delete(self, resource_id: str) -> bool:
        """Delete a document by id. Returns ``False`` if it did not exist."""
        container = self._ensure_container()
        try:
            container.delete_item(item=resource_id, partition_key=resource_id)
            return True
        except exceptions.CosmosResourceNotFoundError:
            return False
