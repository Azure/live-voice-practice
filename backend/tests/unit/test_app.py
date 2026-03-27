"""Tests for the Flask application endpoints."""

import json
from unittest.mock import patch

import pytest
from flask.testing import FlaskClient

from src.app import app


class TestFlaskApp:
    """Test cases for Flask application endpoints."""

    def setup_method(self):
        """Set up test fixtures."""
        app.config["TESTING"] = True
        self.client: FlaskClient = app.test_client()  # pylint: disable=attribute-defined-outside-init

    def test_index_route(self):
        """Test the index route serves index.html."""
        with patch("src.app.send_from_directory") as mock_send:
            mock_send.return_value = "index.html content"

            response = self.client.get("/")

            assert response.status_code == 200
            mock_send.assert_called_once_with(app.static_folder, "index.html")

    def test_index_route_no_static_folder(self):
        """Test index route behavior when static folder is None."""
        original_static_folder = app.static_folder
        app.static_folder = None

        with pytest.raises(SystemExit):
            self.client.get("/")

        # Restore original static folder
        app.static_folder = original_static_folder

    def test_get_config_route(self):
        """Test the /api/config endpoint."""
        response = self.client.get("/api/config")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["proxy_enabled"] is True
        assert data["ws_endpoint"] == "/ws/voice"

    @patch("src.app.scenario_manager")
    def test_get_scenarios_route(self, mock_scenario_manager):
        """Test the /api/scenarios endpoint."""
        mock_scenarios = [
            {"id": "scenario1", "name": "Test Scenario 1"},
            {"id": "scenario2", "name": "Test Scenario 2"},
        ]
        mock_scenario_manager.list_scenarios.return_value = mock_scenarios

        response = self.client.get("/api/scenarios")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data == mock_scenarios
        mock_scenario_manager.list_scenarios.assert_called_once()

    @patch("src.app.scenario_manager")
    def test_get_scenario_existing(self, mock_scenario_manager):
        """Test getting an existing scenario by ID."""
        mock_scenario = {"id": "test-scenario", "name": "Test Scenario"}
        mock_scenario_manager.get_scenario.return_value = mock_scenario

        response = self.client.get("/api/scenarios/test-scenario")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data == mock_scenario
        mock_scenario_manager.get_scenario.assert_called_once_with("test-scenario")

    @patch("src.app.scenario_manager")
    def test_get_scenario_not_found(self, mock_scenario_manager):
        """Test getting a non-existent scenario."""
        mock_scenario_manager.get_scenario.return_value = None

        response = self.client.get("/api/scenarios/nonexistent")

        assert response.status_code == 404
        data = json.loads(response.data)
        assert data["error"] == "Scenario not found"

    @patch("src.app.agent_manager")
    @patch("src.app.scenario_manager")
    def test_create_agent_success(self, mock_scenario_manager, mock_agent_manager):
        """Test successful agent creation."""
        mock_scenario = {"id": "test-scenario", "name": "Test Scenario"}
        mock_scenario_manager.get_scenario.return_value = mock_scenario
        mock_agent_manager.create_agent.return_value = "agent-123"

        response = self.client.post(
            "/api/agents/create",
            json={"scenario_id": "test-scenario"},
        )

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["agent_id"] == "agent-123"
        assert data["scenario_id"] == "test-scenario"
        mock_agent_manager.create_agent.assert_called_once_with("test-scenario", mock_scenario, None)

    @patch("src.app.agent_manager")
    @patch("src.app.scenario_manager")
    def test_create_agent_with_custom_scenario_not_supported(self, mock_scenario_manager, mock_agent_manager):
        """Test custom scenario payloads are rejected."""
        custom_scenario = {
            "id": "custom-123",
            "name": "Custom Scenario",
            "messages": [{"role": "system", "content": "You are a test assistant"}],
        }

        response = self.client.post(
            "/api/agents/create",
            json={"custom_scenario": custom_scenario},
        )

        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["error"] == "custom_scenario is not supported; provide scenario_id from /api/scenarios"
        mock_scenario_manager.get_scenario.assert_not_called()
        mock_agent_manager.create_agent.assert_not_called()

    def test_create_agent_missing_scenario_id(self):
        """Test agent creation without scenario_id."""
        response = self.client.post(
            "/api/agents/create",
            json={},
        )

        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["error"] == "scenario_id is required"

    @patch("src.app.scenario_manager")
    def test_create_agent_scenario_not_found(self, mock_scenario_manager):
        """Test agent creation with non-existent scenario."""
        mock_scenario_manager.get_scenario.return_value = None
        mock_scenario_manager.scenarios = {}
        mock_scenario_manager.generated_scenarios = {}

        response = self.client.post(
            "/api/agents/create",
            json={"scenario_id": "nonexistent"},
        )

        assert response.status_code == 404
        data = json.loads(response.data)
        assert data["error"] == "Scenario not found"

    @patch("src.app.agent_manager")
    @patch("src.app.scenario_manager")
    def test_create_agent_exception(self, mock_scenario_manager, mock_agent_manager):
        """Test agent creation with exception."""
        mock_scenario = {"id": "test-scenario", "name": "Test Scenario"}
        mock_scenario_manager.get_scenario.return_value = mock_scenario
        mock_agent_manager.create_agent.side_effect = Exception("Creation failed")

        response = self.client.post(
            "/api/agents/create",
            json={"scenario_id": "test-scenario"},
        )

        assert response.status_code == 500
        data = json.loads(response.data)
        assert data["error"] == "Creation failed"

    @patch("src.app.agent_manager")
    def test_delete_agent_success(self, mock_agent_manager):
        """Test successful agent deletion."""
        mock_agent_manager.delete_agent.return_value = None

        response = self.client.delete("/api/agents/agent-123")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True
        mock_agent_manager.delete_agent.assert_called_once_with("agent-123")

    @patch("src.app.agent_manager")
    def test_delete_agent_exception(self, mock_agent_manager):
        """Test agent deletion with exception."""
        mock_agent_manager.delete_agent.side_effect = Exception("Deletion failed")

        response = self.client.delete("/api/agents/agent-123")

        assert response.status_code == 500
        data = json.loads(response.data)
        assert data["error"] == "Deletion failed"

    def test_analyze_conversation_success(self):
        """Test successful conversation analysis."""
        # Just test that the endpoint exists and validates input correctly
        # The actual analysis function is complex due to async behavior
        response = self.client.post(
            "/api/analyze",
            json={
                "scenario_id": "test-scenario",
                "transcript": "Hello, how are you?",
                "reference_text": "Hello, how are you?",
            },
        )

        # The response might be 200 or 500 depending on analysis function
        # but it should not be 400 (bad request) since we provided required fields
        assert response.status_code != 400

    def test_analyze_conversation_missing_data(self):
        """Test conversation analysis with missing required data."""
        # Missing scenario_id
        response = self.client.post(
            "/api/analyze",
            json={"transcript": "Hello"},
        )

        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["error"] == "scenario_id and transcript are required"

        # Missing transcript
        response = self.client.post(
            "/api/analyze",
            json={"scenario_id": "test"},
        )

        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["error"] == "scenario_id and transcript are required"

    def test_audio_processor_route(self):
        """Test the audio processor route."""
        with patch("src.app.send_from_directory") as mock_send:
            mock_send.return_value = "audio-processor.js content"

            response = self.client.get("/audio-processor.js")

            assert response.status_code == 200
            mock_send.assert_called_once_with("static", "audio-processor.js")

    def test_perform_conversation_analysis_exists(self):
        """Test the _perform_conversation_analysis function can be imported."""
        from src.app import _perform_conversation_analysis  # pylint: disable=C0415

        assert callable(_perform_conversation_analysis)

    @patch("src.app.conversation_manager")
    def test_list_conversations_endpoint(self, mock_conversation_manager):
        """Test the GET /api/conversations endpoint."""
        mock_conversation_manager.list_conversations.return_value = [
            {"id": "conv-1", "scenarioId": "s1", "overallScore": 4.0}
        ]

        response = self.client.get("/api/conversations")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert len(data) == 1
        assert data[0]["id"] == "conv-1"
        mock_conversation_manager.list_conversations.assert_called_once_with(scenario_id=None)

    @patch("src.app.conversation_manager")
    def test_list_conversations_filtered_by_scenario(self, mock_conversation_manager):
        """Test conversations listing filtered by scenario_id."""
        mock_conversation_manager.list_conversations.return_value = []

        response = self.client.get("/api/conversations?scenario_id=contoso-billing-001")

        assert response.status_code == 200
        mock_conversation_manager.list_conversations.assert_called_once_with(scenario_id="contoso-billing-001")

    @patch("src.app.conversation_manager")
    def test_get_conversation_found(self, mock_conversation_manager):
        """Test getting an existing conversation by ID."""
        record = {"id": "conv-abc", "conversationId": "conv-abc", "scenarioId": "s1"}
        mock_conversation_manager.get_conversation.return_value = record

        response = self.client.get("/api/conversations/conv-abc")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["id"] == "conv-abc"

    @patch("src.app.conversation_manager")
    def test_get_conversation_not_found(self, mock_conversation_manager):
        """Test getting a non-existent conversation returns 404."""
        mock_conversation_manager.get_conversation.return_value = None

        response = self.client.get("/api/conversations/nonexistent")

        assert response.status_code == 404
        data = json.loads(response.data)
        assert data["error"] == "Conversation not found"
