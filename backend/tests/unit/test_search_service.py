"""Tests for the SupportMaterialsSearchService."""

from unittest.mock import Mock, patch

import pytest

from src.services.search_service import SupportMaterialsSearchService


class TestSupportMaterialsSearchService:
    """Test supporting materials search service."""

    def _make_service(self, mock_openai=None, mock_search_client=None):
        """Create a service instance with mocked dependencies."""
        with patch("src.services.search_service.SearchClient") as mock_sc_cls:
            mock_sc_cls.return_value = mock_search_client or Mock()

            service = SupportMaterialsSearchService(
                search_endpoint="https://test-search.search.windows.net",
                index_name="support-materials",
                openai_client=mock_openai or Mock(),
                embedding_deployment="text-embedding-3-small",
                search_api_key="test-key",
            )
        return service

    def test_initialization(self):
        """Test service initializes successfully."""
        service = self._make_service()
        assert service is not None

    @pytest.mark.asyncio
    async def test_search_returns_documents(self):
        """Test search returns matched documents."""
        mock_openai = Mock()
        mock_embedding_response = Mock()
        mock_embedding_response.data = [Mock(embedding=[0.1] * 1536)]
        mock_openai.embeddings.create.return_value = mock_embedding_response

        mock_result_1 = {"title": "Policy A", "content": "Content A", "sourcePath": "/a.pdf", "materialType": "pdf"}
        mock_result_2 = {"title": "Policy B", "content": "Content B", "sourcePath": "/b.pdf", "materialType": "pdf"}

        mock_search_client = Mock()
        mock_search_client.search.return_value = iter([mock_result_1, mock_result_2])

        service = self._make_service(mock_openai=mock_openai, mock_search_client=mock_search_client)
        service._search_client = mock_search_client

        results = await service.search_supporting_materials("billing policy")

        assert len(results) == 2
        assert results[0]["title"] == "Policy A"
        assert results[1]["content"] == "Content B"

    @pytest.mark.asyncio
    async def test_search_returns_empty_on_error(self):
        """Test search returns empty list on exceptions."""
        mock_openai = Mock()
        mock_openai.embeddings.create.side_effect = Exception("API error")

        service = self._make_service(mock_openai=mock_openai)

        results = await service.search_supporting_materials("test query")
        assert results == []

    @pytest.mark.asyncio
    async def test_search_filters_empty_content(self):
        """Test search filters out results with empty content."""
        mock_openai = Mock()
        mock_embedding_response = Mock()
        mock_embedding_response.data = [Mock(embedding=[0.1] * 1536)]
        mock_openai.embeddings.create.return_value = mock_embedding_response

        mock_result = {"title": "Empty", "content": "", "sourcePath": "", "materialType": ""}

        mock_search_client = Mock()
        mock_search_client.search.return_value = iter([mock_result])

        service = self._make_service(mock_openai=mock_openai, mock_search_client=mock_search_client)
        service._search_client = mock_search_client

        results = await service.search_supporting_materials("test query")
        assert results == []

    def test_generate_embedding(self):
        """Test embedding generation calls OpenAI correctly."""
        mock_openai = Mock()
        mock_embedding_response = Mock()
        mock_embedding_response.data = [Mock(embedding=[0.5] * 1536)]
        mock_openai.embeddings.create.return_value = mock_embedding_response

        service = self._make_service(mock_openai=mock_openai)

        embedding = service._generate_embedding("test text")

        assert len(embedding) == 1536
        mock_openai.embeddings.create.assert_called_once_with(
            input="test text",
            model="text-embedding-3-small",
        )
