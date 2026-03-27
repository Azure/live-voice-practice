# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Cosmos DB service for managing user role assignments."""

import logging
from typing import Optional

from azure.cosmos import CosmosClient, exceptions
from azure.identity import DefaultAzureCredential

from src.config import config

logger = logging.getLogger(__name__)

# Only trainers are stored; absence means trainee
TRAINER_ROLE = "trainer"
TRAINEE_ROLE = "trainee"


class RoleStore:
    """Service for looking up user roles in Cosmos DB."""

    def __init__(self):
        self._client: Optional[CosmosClient] = None
        self._container = None
        self._initialized = False

    def _ensure_initialized(self) -> bool:
        if self._initialized:
            return self._container is not None

        endpoint = config.get("cosmos_endpoint")
        database_name = config.get("cosmos_database_name", "voicelab")
        container_name = config.get("cosmos_role_assignments_container", "role_assignments")

        if not endpoint:
            logger.warning("cosmos_endpoint not configured, role store disabled")
            self._initialized = True
            return False

        try:
            credential = DefaultAzureCredential()
            self._client = CosmosClient(endpoint, credential=credential)
            database = self._client.get_database_client(database_name)
            self._container = database.get_container_client(container_name)
            logger.info("RoleStore initialized: %s/%s", database_name, container_name)
            self._initialized = True
            return True
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to initialize RoleStore: %s", e)
            self._initialized = True
            return False

    def get_user_role(self, user_id: str) -> str:
        """Get the role for a user. Returns 'trainer' if found, 'trainee' otherwise."""
        if not self._ensure_initialized():
            return TRAINEE_ROLE

        if self._container is None:
            return TRAINEE_ROLE

        try:
            items = list(
                self._container.query_items(
                    query="SELECT * FROM c WHERE c.userId = @userId",
                    parameters=[{"name": "@userId", "value": user_id}],
                    partition_key=user_id,
                )
            )
            if items and items[0].get("role") == TRAINER_ROLE:
                return TRAINER_ROLE
            return TRAINEE_ROLE
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to get user role: %s", e)
            return TRAINEE_ROLE

    def is_trainer(self, user_id: str) -> bool:
        return self.get_user_role(user_id) == TRAINER_ROLE


# Singleton instance
role_store = RoleStore()
