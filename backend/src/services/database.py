# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Cosmos DB service for storing and retrieving user conversations."""

import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from azure.cosmos import CosmosClient, exceptions
from azure.identity import DefaultAzureCredential

from src.config import config

logger = logging.getLogger(__name__)


class ConversationStore:
    """Service for managing conversation records in Cosmos DB."""

    def __init__(self):
        """Initialize the Cosmos DB client and container."""
        self._client: Optional[CosmosClient] = None
        self._container = None
        self._initialized = False

    def _ensure_initialized(self) -> bool:
        """Lazily initialize the Cosmos DB connection.

        Returns:
            True if initialization was successful, False otherwise.
        """
        if self._initialized:
            return self._container is not None

        endpoint = config.get("cosmos_endpoint")
        database_name = config.get("cosmos_database_name", "voicelab")
        container_name = config.get("cosmos_conversations_container", "conversations")

        if not endpoint:
            logger.warning("cosmos_endpoint not configured, conversation storage disabled")
            self._initialized = True
            return False

        try:
            # Use DefaultAzureCredential for authentication (works with managed identity)
            credential = DefaultAzureCredential()
            self._client = CosmosClient(endpoint, credential=credential)

            # Get or create database
            database = self._client.get_database_client(database_name)

            # Get or create container with user_id as partition key
            self._container = database.get_container_client(container_name)

            logger.info("Cosmos DB initialized successfully: %s/%s", database_name, container_name)
            self._initialized = True
            return True

        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to initialize Cosmos DB: %s", e)
            self._initialized = True
            return False

    def save_conversation(
        self,
        user_id: str,
        scenario_id: str,
        transcript: str,
        assessment: Optional[Dict[str, Any]] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Optional[str]:
        """Save a conversation record to Cosmos DB.

        Args:
            user_id: The ID of the user who owns this conversation.
            scenario_id: The ID of the scenario used in this conversation.
            transcript: The full conversation transcript.
            assessment: Optional assessment results (AI and pronunciation).
            metadata: Optional additional metadata.

        Returns:
            The ID of the created conversation record, or None if storage failed.
        """
        if not self._ensure_initialized():
            return None

        if self._container is None:
            return None

        conversation_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()

        document = {
            "id": conversation_id,
            "user_id": user_id,  # Partition key
            "scenario_id": scenario_id,
            "transcript": transcript,
            "assessment": assessment,
            "status": "analyzed" if assessment else "in_progress",
            "metadata": metadata or {},
            "created_at": now,
            "updated_at": now,
        }

        try:
            self._container.create_item(body=document)
            logger.info("Saved conversation %s for user %s", conversation_id, user_id)
            return conversation_id
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to save conversation: %s", e)
            return None

    def create_conversation(
        self,
        user_id: str,
        scenario_id: str,
        messages: Optional[List[Dict[str, Any]]] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Optional[str]:
        """Create an in-progress conversation record.

        Args:
            user_id: The ID of the user who owns this conversation.
            scenario_id: The ID of the scenario.
            messages: Optional initial conversation messages.
            metadata: Optional additional metadata.

        Returns:
            The ID of the created conversation, or None if storage failed.
        """
        if not self._ensure_initialized():
            return None

        if self._container is None:
            return None

        conversation_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()

        document = {
            "id": conversation_id,
            "user_id": user_id,
            "scenario_id": scenario_id,
            "transcript": "",
            "messages": messages or [],
            "assessment": None,
            "status": "in_progress",
            "metadata": metadata or {},
            "created_at": now,
            "updated_at": now,
        }

        try:
            self._container.create_item(body=document)
            logger.info("Created in-progress conversation %s for user %s", conversation_id, user_id)
            return conversation_id
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to create conversation: %s", e)
            return None

    def update_conversation_messages(
        self,
        user_id: str,
        conversation_id: str,
        messages: List[Dict[str, Any]],
        transcript: str = "",
    ) -> bool:
        """Update messages on an existing conversation.

        Args:
            user_id: The user ID (partition key).
            conversation_id: The conversation ID.
            messages: Updated list of messages.
            transcript: Updated transcript text.

        Returns:
            True on success, False on failure.
        """
        if not self._ensure_initialized():
            return False

        if self._container is None:
            return False

        try:
            item = self._container.read_item(item=conversation_id, partition_key=user_id)
            item["messages"] = messages
            item["transcript"] = transcript
            item["updated_at"] = datetime.now(timezone.utc).isoformat()
            self._container.replace_item(item=conversation_id, body=item)
            logger.info("Updated messages for conversation %s", conversation_id)
            return True
        except exceptions.CosmosResourceNotFoundError:
            logger.warning("Conversation %s not found for update", conversation_id)
            return False
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to update conversation messages: %s", e)
            return False

    def update_conversation_assessment(
        self,
        user_id: str,
        conversation_id: str,
        transcript: str,
        assessment: Dict[str, Any],
        messages: Optional[List[Dict[str, Any]]] = None,
    ) -> bool:
        """Update an existing conversation with assessment results.

        Args:
            user_id: The user ID (partition key).
            conversation_id: The conversation ID.
            transcript: Final transcript text.
            assessment: Assessment results.
            messages: Optional final messages list.

        Returns:
            True on success, False on failure.
        """
        if not self._ensure_initialized():
            return False

        if self._container is None:
            return False

        try:
            item = self._container.read_item(item=conversation_id, partition_key=user_id)
            item["transcript"] = transcript
            item["assessment"] = assessment
            item["status"] = "analyzed"
            item["updated_at"] = datetime.now(timezone.utc).isoformat()
            if messages is not None:
                item["messages"] = messages
            self._container.replace_item(item=conversation_id, body=item)
            logger.info("Updated conversation %s with assessment", conversation_id)
            return True
        except exceptions.CosmosResourceNotFoundError:
            logger.warning("Conversation %s not found for assessment update", conversation_id)
            return False
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to update conversation assessment: %s", e)
            return False

    def get_conversation(self, user_id: str, conversation_id: str) -> Optional[Dict[str, Any]]:
        """Get a specific conversation by ID.

        Args:
            user_id: The user ID (required for partition key lookup).
            conversation_id: The conversation ID.

        Returns:
            The conversation document, or None if not found.
        """
        if not self._ensure_initialized():
            return None

        if self._container is None:
            return None

        try:
            item = self._container.read_item(item=conversation_id, partition_key=user_id)
            return dict(item)
        except exceptions.CosmosResourceNotFoundError:
            logger.warning("Conversation %s not found for user %s", conversation_id, user_id)
            return None
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to get conversation: %s", e)
            return None

    # Whitelist of allowed sort columns to prevent injection
    _ALLOWED_SORT_COLUMNS = {"created_at", "updated_at", "scenario_id"}

    def list_user_conversations(
        self,
        user_id: str,
        limit: int = 20,
        offset: int = 0,
        sort_by: str = "created_at",
        sort_order: str = "desc",
    ) -> Dict[str, Any]:
        """List conversations for a specific user with pagination and sorting.

        Args:
            user_id: The user ID to filter by.
            limit: Maximum number of conversations to return.
            offset: Number of conversations to skip.
            sort_by: Column to sort by (created_at, updated_at, scenario_id).
            sort_order: Sort direction (asc or desc).

        Returns:
            Dict with 'items' (list of conversation summaries) and 'total' count.
        """
        empty_result: Dict[str, Any] = {"items": [], "total": 0}

        if not self._ensure_initialized():
            return empty_result

        if self._container is None:
            return empty_result

        # Validate sort parameters against whitelist
        if sort_by not in self._ALLOWED_SORT_COLUMNS:
            sort_by = "created_at"
        if sort_order.lower() not in ("asc", "desc"):
            sort_order = "desc"

        try:
            # Count query for total
            count_query = "SELECT VALUE COUNT(1) FROM c WHERE c.user_id = @user_id"
            count_params: List[Dict[str, Any]] = [{"name": "@user_id", "value": user_id}]
            count_results = list(
                self._container.query_items(
                    query=count_query,
                    parameters=count_params,
                    partition_key=user_id,
                )
            )
            total = count_results[0] if count_results else 0

            # Data query with sorting and pagination
            query = f"""
                SELECT c.id, c.user_id, c.scenario_id, c.assessment,
                       c.metadata, c.status, c.created_at, c.updated_at
                FROM c
                WHERE c.user_id = @user_id
                ORDER BY c.{sort_by} {sort_order.upper()}
                OFFSET @offset LIMIT @limit
            """
            parameters: List[Dict[str, Any]] = [
                {"name": "@user_id", "value": user_id},
                {"name": "@offset", "value": offset},
                {"name": "@limit", "value": limit},
            ]

            items = list(
                self._container.query_items(
                    query=query,
                    parameters=parameters,
                    partition_key=user_id,
                )
            )
            return {"items": [dict(item) for item in items], "total": total}

        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to list conversations: %s", e)
            return empty_result

    def delete_conversation(self, user_id: str, conversation_id: str) -> bool:
        """Delete a conversation.

        Args:
            user_id: The user ID (required for partition key).
            conversation_id: The conversation ID to delete.

        Returns:
            True if deleted successfully, False otherwise.
        """
        if not self._ensure_initialized():
            return False

        if self._container is None:
            return False

        try:
            self._container.delete_item(item=conversation_id, partition_key=user_id)
            logger.info("Deleted conversation %s for user %s", conversation_id, user_id)
            return True
        except exceptions.CosmosResourceNotFoundError:
            logger.warning("Conversation %s not found for deletion", conversation_id)
            return False
        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to delete conversation: %s", e)
            return False

    def get_conversation_by_id_admin(self, conversation_id: str) -> Optional[Dict[str, Any]]:
        """Get a conversation by ID (admin only - cross-partition query).

        This is less efficient as it requires a cross-partition query.
        Use only for admin access when user_id is not known.

        Args:
            conversation_id: The conversation ID.

        Returns:
            The conversation document, or None if not found.
        """
        if not self._ensure_initialized():
            return None

        if self._container is None:
            return None

        try:
            query = "SELECT * FROM c WHERE c.id = @id"
            parameters: List[Dict[str, Any]] = [{"name": "@id", "value": conversation_id}]

            items = list(
                self._container.query_items(
                    query=query,
                    parameters=parameters,
                    enable_cross_partition_query=True,
                )
            )

            if items:
                return dict(items[0])
            return None

        except exceptions.CosmosHttpResponseError as e:
            logger.error("Failed to get conversation by admin: %s", e)
            return None


# Singleton instance
conversation_store = ConversationStore()
