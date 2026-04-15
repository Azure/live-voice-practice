# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Supporting materials retrieval service using Azure AI Search (hybrid search)."""

import asyncio
import logging
from typing import Any, Dict, List

from azure.core.credentials import AzureKeyCredential
from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from openai import AzureOpenAI

logger = logging.getLogger(__name__)

# Defaults
DEFAULT_VECTOR_FIELD = "contentVector"
DEFAULT_EMBEDDING_DIMENSIONS = 1536
DEFAULT_TOP = 3


class SupportMaterialsSearchService:
    """Retrieves supporting materials from Azure AI Search using hybrid (keyword + vector) search."""

    def __init__(
        self,
        search_endpoint: str,
        index_name: str,
        openai_client: AzureOpenAI,
        embedding_deployment: str,
        search_api_key: str = "",
    ):
        """
        Initialize the search service.

        Args:
            search_endpoint: Azure AI Search endpoint URL
            index_name: Name of the search index (e.g. 'support-materials')
            openai_client: AzureOpenAI client for generating query embeddings
            embedding_deployment: Deployment name for the embedding model (e.g. 'text-embedding-3-small')
            search_api_key: Optional API key for search service, falls back to managed identity
        """
        self._openai_client = openai_client
        self._embedding_deployment = embedding_deployment

        credential: Any
        if search_api_key:
            credential = AzureKeyCredential(search_api_key)
        else:
            credential = DefaultAzureCredential()

        self._search_client = SearchClient(
            endpoint=search_endpoint,
            index_name=index_name,
            credential=credential,
        )
        logger.info(
            "SupportMaterialsSearchService initialized — endpoint: %s, index: %s",
            search_endpoint,
            index_name,
        )

    def _generate_embedding(self, text: str) -> List[float]:
        """Generate an embedding vector for the given text using the OpenAI embeddings API."""
        response = self._openai_client.embeddings.create(
            input=text,
            model=self._embedding_deployment,
        )
        return response.data[0].embedding

    async def search_supporting_materials(
        self,
        query: str,
        top: int = DEFAULT_TOP,
    ) -> List[Dict[str, Any]]:
        """
        Search for supporting materials using hybrid (keyword + vector) search.

        Args:
            query: The search query text (will also be embedded for vector search)
            top: Maximum number of results to return

        Returns:
            List of matching documents with title and content fields.
            Returns an empty list if the search fails for any reason.
        """
        try:
            embedding = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: self._generate_embedding(query[:8000]),
            )

            vector_query = VectorizedQuery(
                vector=embedding,
                k_nearest_neighbors=top,
                fields=DEFAULT_VECTOR_FIELD,
            )

            results = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: self._search_client.search(
                    search_text=query[:1000],
                    vector_queries=[vector_query],
                    top=top,
                    select=["title", "content", "sourcePath", "materialType"],
                ),
            )

            documents: List[Dict[str, Any]] = []
            for result in results:
                doc = {
                    "title": result.get("title", ""),
                    "content": result.get("content", ""),
                    "sourcePath": result.get("sourcePath", ""),
                    "materialType": result.get("materialType", ""),
                }
                if doc["content"]:
                    documents.append(doc)

            logger.info("AI Search returned %d supporting materials for query", len(documents))
            return documents

        except Exception as e:
            logger.warning("Supporting materials search failed (non-blocking): %s", e)
            return []
