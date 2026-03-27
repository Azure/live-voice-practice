"""Tests for ConversationManager service."""

from unittest.mock import MagicMock, patch


from src.services.conversation_manager import ConversationManager


SAMPLE_RUBRIC = {
    "rubricId": "contoso-rubric-billing-v1",
    "appliesTo": {"scenarioIds": ["contoso-billing-001"]},
    "criteria": [
        {
            "criterionId": "empathy",
            "name": "Empathy and Professionalism",
            "description": "Assesses empathy.",
            "levels": [
                {"level": 1, "label": "Poor", "description": "Dismissive."},
                {"level": 3, "label": "Adequate", "description": "Inconsistent."},
                {"level": 5, "label": "Excellent", "description": "Clearly acknowledges."},
            ],
        },
        {
            "criterionId": "clarity",
            "name": "Clarity of Explanation",
            "description": "Evaluates clarity.",
            "levels": [
                {"level": 1, "label": "Unclear", "description": "Vague."},
                {"level": 5, "label": "Very Clear", "description": "Structured."},
            ],
        },
    ],
    "scoring": {"scale": "1-5", "overallScoreMethod": "average", "passThreshold": 3.5},
}


class TestConversationManager:
    """Test conversation manager functionality."""

    @patch("src.services.conversation_manager.config")
    def test_init_no_cosmos_endpoint(self, mock_config):
        """ConversationManager gracefully handles missing Cosmos endpoint."""
        mock_config.get.return_value = ""
        manager = ConversationManager()
        assert manager.cosmos_client is None
        assert manager.rubrics == {}

    @patch("src.services.conversation_manager.CosmosClient")
    @patch("src.services.conversation_manager.config")
    def test_load_rubrics_indexes_by_scenario(self, mock_config, mock_cosmos_cls):
        """Rubrics are indexed by scenarioId from appliesTo."""
        mock_config.get.side_effect = lambda key, default="": {
            "cosmos_endpoint": "https://fake.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "testdb",
            "cosmos_rubrics_container": "rubrics",
            "cosmos_conversations_container": "conversations",
        }.get(key, default)

        mock_container = MagicMock()
        mock_container.read_all_items.return_value = [SAMPLE_RUBRIC]
        mock_cosmos_cls.return_value.get_database_client.return_value.get_container_client.return_value = mock_container

        manager = ConversationManager()

        assert "contoso-billing-001" in manager.rubrics
        assert manager.rubrics["contoso-billing-001"]["rubricId"] == "contoso-rubric-billing-v1"

    def test_get_rubric_for_scenario_returns_none_when_empty(self):
        """Returns None when no rubric matches the scenario."""
        with patch("src.services.conversation_manager.config") as mock_config:
            mock_config.get.return_value = ""
            manager = ConversationManager()
            assert manager.get_rubric_for_scenario("nonexistent") is None

    @patch("src.services.conversation_manager.CosmosClient")
    @patch("src.services.conversation_manager.config")
    def test_save_conversation_returns_id(self, mock_config, mock_cosmos_cls):
        """save_conversation creates item and returns conversation ID."""
        mock_config.get.side_effect = lambda key, default="": {
            "cosmos_endpoint": "https://fake.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "testdb",
            "cosmos_rubrics_container": "rubrics",
            "cosmos_conversations_container": "conversations",
        }.get(key, default)

        mock_container = MagicMock()
        mock_container.read_all_items.return_value = []
        mock_container.create_item.return_value = None
        mock_cosmos_cls.return_value.get_database_client.return_value.get_container_client.return_value = mock_container

        manager = ConversationManager()

        conv_id = manager.save_conversation(
            scenario_id="contoso-billing-001",
            transcript="Hello, I have a billing issue.",
            conversation_messages=[
                {"role": "user", "content": "Hello, I have a billing issue."},
                {"role": "assistant", "content": "I can help with that."},
            ],
            evaluation={"overall_score": 4.2, "passed": True},
        )

        assert conv_id is not None
        assert conv_id.startswith("conv-")
        mock_container.create_item.assert_called_once()

        saved_record = mock_container.create_item.call_args[0][0]
        assert saved_record["scenarioId"] == "contoso-billing-001"
        assert saved_record["transcriptText"] == "Hello, I have a billing issue."
        assert saved_record["transcript"] == [
            {"order": 1, "role": "user", "content": "Hello, I have a billing issue."},
            {"order": 2, "role": "assistant", "content": "I can help with that."},
        ]
        assert saved_record["evaluation"]["overall_score"] == 4.2

    @patch("src.services.conversation_manager.config")
    def test_save_conversation_returns_none_when_no_client(self, mock_config):
        """save_conversation returns None when Cosmos is not configured."""
        mock_config.get.return_value = ""
        manager = ConversationManager()
        result = manager.save_conversation("s1", "transcript")
        assert result is None

    @patch("src.services.conversation_manager.CosmosClient")
    @patch("src.services.conversation_manager.config")
    def test_save_conversation_falls_back_to_parsed_transcript(self, mock_config, mock_cosmos_cls):
        """Legacy transcript text is parsed into ordered message items when list is absent."""
        mock_config.get.side_effect = lambda key, default="": {
            "cosmos_endpoint": "https://fake.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "testdb",
            "cosmos_rubrics_container": "rubrics",
            "cosmos_conversations_container": "conversations",
        }.get(key, default)

        mock_container = MagicMock()
        mock_container.read_all_items.return_value = []
        mock_container.create_item.return_value = None
        mock_cosmos_cls.return_value.get_database_client.return_value.get_container_client.return_value = mock_container

        manager = ConversationManager()
        manager.save_conversation(
            scenario_id="contoso-billing-001",
            transcript="user: first message\nassistant: second message",
            evaluation={"overall_score": 3.5, "passed": False},
        )

        saved_record = mock_container.create_item.call_args[0][0]
        assert saved_record["transcript"] == [
            {"order": 1, "role": "user", "content": "first message"},
            {"order": 2, "role": "assistant", "content": "second message"},
        ]

    @patch("src.services.conversation_manager.CosmosClient")
    @patch("src.services.conversation_manager.config")
    def test_get_conversation(self, mock_config, mock_cosmos_cls):
        """get_conversation reads item from Cosmos by ID."""
        mock_config.get.side_effect = lambda key, default="": {
            "cosmos_endpoint": "https://fake.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "testdb",
            "cosmos_rubrics_container": "rubrics",
            "cosmos_conversations_container": "conversations",
        }.get(key, default)

        expected = {"id": "conv-abc123", "conversationId": "conv-abc123", "scenarioId": "s1"}
        mock_container = MagicMock()
        mock_container.read_all_items.return_value = []
        mock_container.read_item.return_value = expected
        mock_cosmos_cls.return_value.get_database_client.return_value.get_container_client.return_value = mock_container

        manager = ConversationManager()
        result = manager.get_conversation("conv-abc123")

        assert result == expected
        mock_container.read_item.assert_called_once_with(item="conv-abc123", partition_key="conv-abc123")

    @patch("src.services.conversation_manager.CosmosClient")
    @patch("src.services.conversation_manager.config")
    def test_list_conversations_with_filter(self, mock_config, mock_cosmos_cls):
        """list_conversations queries by scenarioId when provided."""
        mock_config.get.side_effect = lambda key, default="": {
            "cosmos_endpoint": "https://fake.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "testdb",
            "cosmos_rubrics_container": "rubrics",
            "cosmos_conversations_container": "conversations",
        }.get(key, default)

        mock_container = MagicMock()
        mock_container.read_all_items.return_value = []
        mock_container.query_items.return_value = [
            {"id": "conv-1", "conversationId": "conv-1", "scenarioId": "s1", "overallScore": 4.0}
        ]
        mock_cosmos_cls.return_value.get_database_client.return_value.get_container_client.return_value = mock_container

        manager = ConversationManager()
        items = manager.list_conversations(scenario_id="s1")

        assert len(items) == 1
        assert items[0]["scenarioId"] == "s1"
        mock_container.query_items.assert_called_once()
        call_kwargs = mock_container.query_items.call_args
        assert "WHERE c.scenarioId = @sid" in call_kwargs.kwargs.get("query", call_kwargs[1].get("query", ""))

    @patch("src.services.conversation_manager.CosmosClient")
    @patch("src.services.conversation_manager.config")
    def test_list_conversations_without_filter(self, mock_config, mock_cosmos_cls):
        """list_conversations uses cross-partition query when no filter."""
        mock_config.get.side_effect = lambda key, default="": {
            "cosmos_endpoint": "https://fake.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "testdb",
            "cosmos_rubrics_container": "rubrics",
            "cosmos_conversations_container": "conversations",
        }.get(key, default)

        mock_container = MagicMock()
        mock_container.read_all_items.return_value = []
        mock_container.query_items.return_value = []
        mock_cosmos_cls.return_value.get_database_client.return_value.get_container_client.return_value = mock_container

        manager = ConversationManager()
        items = manager.list_conversations()

        assert items == []
        call_kwargs = mock_container.query_items.call_args
        assert call_kwargs.kwargs.get("enable_cross_partition_query", call_kwargs[1].get("enable_cross_partition_query")) is True
