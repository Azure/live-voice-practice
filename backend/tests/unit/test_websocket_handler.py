"""Tests for the websocket_handler module."""

from unittest.mock import AsyncMock, Mock, patch

import pytest

from src.services.websocket_handler import VoiceProxyHandler


class TestVoiceProxyHandler:
    """Test cases for VoiceProxyHandler."""

    def test_voice_proxy_handler_initialization(self):
        """Test handler initialization."""
        agent_manager = Mock()

        handler = VoiceProxyHandler(agent_manager)

        assert handler.agent_manager == agent_manager

    @patch("src.services.websocket_handler.config")
    def test_build_endpoint(self, mock_config):
        """Test building the Azure endpoint URL."""
        mock_config.__getitem__.side_effect = lambda key: {
            "azure_ai_resource_name": "test-resource",
        }.get(key, "default")
        mock_config.get = lambda key, default=None: {
            "realtime_azure_ai_resource_name": "test-resource",
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        endpoint = handler._build_endpoint()

        assert endpoint == "https://test-resource.cognitiveservices.azure.com"

    @patch("src.services.websocket_handler.config")
    def test_build_endpoint_cross_region(self, mock_config):
        """Test building endpoint URL when realtime model is in a different region."""
        mock_config.__getitem__.side_effect = lambda key: {
            "azure_ai_resource_name": "primary-resource",
        }.get(key, "default")
        mock_config.get = lambda key, default=None: {
            "realtime_azure_ai_resource_name": "realtime-resource",
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        endpoint = handler._build_endpoint()

        assert endpoint == "https://realtime-resource.cognitiveservices.azure.com"

    @patch("src.services.websocket_handler.config")
    def test_build_endpoint_fallback_to_primary(self, mock_config):
        """Test building endpoint URL falls back to primary resource when realtime not set."""
        mock_config.__getitem__.side_effect = lambda key: {
            "azure_ai_resource_name": "primary-resource",
        }.get(key, "default")
        mock_config.get = lambda key, default=None: {
            "realtime_azure_ai_resource_name": "",
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        endpoint = handler._build_endpoint()

        assert endpoint == "https://primary-resource.cognitiveservices.azure.com"

    @patch("src.services.websocket_handler.config")
    def test_get_model_with_azure_agent(self, mock_config):
        """Test getting model name with Azure agent configuration."""
        handler = VoiceProxyHandler(Mock())
        agent_config = {"is_azure_agent": True, "model": "gpt-4o"}

        model = handler._get_model(agent_config)

        assert model is None

    @patch("src.services.websocket_handler.config")
    def test_get_model_with_local_agent(self, mock_config):
        """Test getting model name with local agent configuration."""
        mock_config.__getitem__.side_effect = lambda key: {
            "realtime_model_deployment_name": "gpt-4o-realtime",
        }.get(key, "default")

        handler = VoiceProxyHandler(Mock())
        agent_config = {"is_azure_agent": False, "model": "gpt-4"}

        model = handler._get_model(agent_config)

        assert model == "gpt-4o-realtime"

    @patch("src.services.websocket_handler.config")
    def test_get_model_without_agent_config_with_global_agent_id(self, mock_config):
        """Test getting model name without agent config but with global agent_id."""
        mock_config.__getitem__.side_effect = lambda key: {
            "agent_id": "static-agent-123",
        }.get(key, "")

        handler = VoiceProxyHandler(Mock())
        model = handler._get_model(None)

        assert model is None

    @patch("src.services.websocket_handler.config")
    def test_get_model_without_agent_config(self, mock_config):
        """Test getting model name without agent config."""
        mock_config.__getitem__.side_effect = lambda key: {
            "agent_id": "",
            "realtime_model_deployment_name": "gpt-4o-realtime",
        }.get(key, "")

        handler = VoiceProxyHandler(Mock())
        model = handler._get_model(None)

        assert model == "gpt-4o-realtime"

    @patch("src.services.websocket_handler.config")
    def test_build_query_params_with_azure_agent(self, mock_config):
        """Test building query params with Azure agent configuration."""
        mock_config.__getitem__.side_effect = lambda key: {
            "azure_ai_project_name": "test-project",
        }.get(key, "")

        handler = VoiceProxyHandler(Mock())
        agent_config = {"is_azure_agent": True}

        params = handler._build_query_params("agent-123", agent_config)

        assert params["agent-id"] == "agent-123"
        assert params["agent-project-name"] == "test-project"

    @patch("src.services.websocket_handler.config")
    def test_build_query_params_with_local_agent(self, mock_config):
        """Test building query params with local agent configuration."""
        handler = VoiceProxyHandler(Mock())
        agent_config = {"is_azure_agent": False}

        params = handler._build_query_params("local-agent-123", agent_config)

        assert params == {}

    @patch("src.services.websocket_handler.config")
    def test_build_query_params_without_agent_config_with_global_agent_id(self, mock_config):
        """Test building query params without agent config but with global agent_id."""
        mock_config.__getitem__.side_effect = lambda key: {
            "agent_id": "static-agent-123",
        }.get(key, "")

        handler = VoiceProxyHandler(Mock())
        params = handler._build_query_params(None, None)

        assert params["agent-id"] == "static-agent-123"

    @patch("src.services.websocket_handler.config")
    def test_build_session_config_without_agent(self, mock_config):
        """Test building session config without agent configuration."""
        mock_config.get.side_effect = lambda key, default=None: {
            "azure_voice_name": "en-US-TestVoice",
            "azure_voice_type": "azure-standard",
            "azure_avatar_character": "lisa",
            "azure_avatar_style": "casual-sitting",
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        session = handler._build_session_config(None)

        assert "modalities" in session
        assert "turn_detection" in session
        assert "voice" in session

    @patch("src.services.websocket_handler.config")
    def test_build_session_config_with_local_agent(self, mock_config):
        """Test building session config with local agent configuration."""
        mock_config.get.side_effect = lambda key, default=None: {
            "azure_voice_name": "en-US-TestVoice",
            "azure_voice_type": "azure-standard",
            "azure_avatar_character": "lisa",
            "azure_avatar_style": "casual-sitting",
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        agent_config = {
            "is_azure_agent": False,
            "instructions": "Test instructions",
            "temperature": 0.8,
            "max_tokens": 1000,
        }

        session = handler._build_session_config(agent_config)

        assert session["instructions"] == "Test instructions"
        assert session["temperature"] == 0.8
        assert session["max_response_output_tokens"] == 1000

    @pytest.mark.asyncio
    async def test_send_message(self):
        """Test sending a message to WebSocket."""
        handler = VoiceProxyHandler(Mock())

        mock_ws = Mock()

        with patch("asyncio.get_event_loop") as mock_loop:
            mock_loop.return_value.run_in_executor = AsyncMock(return_value=None)

            message = {"type": "test", "data": "test data"}
            await handler._send_message(mock_ws, message)

            mock_loop.return_value.run_in_executor.assert_called_once()

    @pytest.mark.asyncio
    async def test_send_error(self):
        """Test sending an error message to WebSocket."""
        handler = VoiceProxyHandler(Mock())

        mock_ws = Mock()

        with patch("asyncio.get_event_loop") as mock_loop:
            mock_loop.return_value.run_in_executor = AsyncMock(return_value=None)

            await handler._send_error(mock_ws, "Test error")

            mock_loop.return_value.run_in_executor.assert_called_once()

    @patch("src.services.websocket_handler.config")
    def test_get_credential_success(self, mock_config):
        """Test getting credential with valid API key."""
        mock_config.get.return_value = "test-api-key"

        handler = VoiceProxyHandler(Mock())
        credential = handler._get_credential()

        assert credential is not None
        assert credential.key == "test-api-key"

    @patch("src.services.websocket_handler.config")
    def test_get_credential_missing_key(self, mock_config):
        """Test getting credential with missing API key uses managed identity."""
        mock_config.get.return_value = None

        with patch("src.services.websocket_handler.DefaultAzureCredential") as mock_default_credential:
            mock_default_credential.return_value = Mock()

            handler = VoiceProxyHandler(Mock())
            credential = handler._get_credential()

            assert credential is not None
            mock_default_credential.assert_called_once()

    @patch("src.services.websocket_handler.config")
    def test_create_request_session_registers_tools_for_local_agent(self, mock_config):
        """Local agents get function tools registered when the feature is enabled."""
        mock_config.get.side_effect = lambda key, default=None: {
            "azure_input_transcription_model": "azure-speech",
            "azure_input_transcription_language": "en-US",
            "enable_realtime_function_calling": True,
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        agent_config = {"is_azure_agent": False, "instructions": "x", "temperature": 0.7, "max_tokens": 500}

        session = handler._create_request_session("voice", "azure-standard", None, agent_config)

        assert "tools" in session
        assert session["tool_choice"] == "auto"
        assert session["tools"][0].name == "get_scenario_context"

    @patch("src.services.websocket_handler.config")
    def test_create_request_session_skips_tools_when_disabled(self, mock_config):
        """The function-calling feature flag suppresses tool registration."""
        mock_config.get.side_effect = lambda key, default=None: {
            "azure_input_transcription_model": "azure-speech",
            "azure_input_transcription_language": "en-US",
            "enable_realtime_function_calling": False,
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        agent_config = {"is_azure_agent": False, "instructions": "x", "temperature": 0.7, "max_tokens": 500}

        session = handler._create_request_session("voice", "azure-standard", None, agent_config)

        assert session.get("tools") is None

    @patch("src.services.websocket_handler.config")
    def test_create_request_session_skips_tools_for_azure_agent(self, mock_config):
        """Azure-hosted agents manage their own tools, so none are registered here."""
        mock_config.get.side_effect = lambda key, default=None: {
            "azure_input_transcription_model": "azure-speech",
            "azure_input_transcription_language": "en-US",
            "enable_realtime_function_calling": True,
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())
        agent_config = {"is_azure_agent": True}

        session = handler._create_request_session("voice", "azure-standard", None, agent_config)

        assert session.get("tools") is None

    @patch("src.services.websocket_handler.config")
    def test_create_request_session_wires_transcription_config(self, mock_config):
        """Input transcription model and language come from configuration."""
        mock_config.get.side_effect = lambda key, default=None: {
            "azure_input_transcription_model": "mai-transcribe-1",
            "azure_input_transcription_language": "en-GB",
            "enable_realtime_function_calling": False,
        }.get(key, default)

        handler = VoiceProxyHandler(Mock())

        session = handler._create_request_session("voice", "azure-standard", None, None)

        assert session["input_audio_transcription"].model == "mai-transcribe-1"
        assert session["input_audio_transcription"].language == "en-GB"

    @pytest.mark.asyncio
    async def test_handle_function_call_returns_output_and_continues(self):
        """A function call is dispatched and the result is fed back to Azure."""
        agent_manager = Mock()
        agent_manager.get_agent.return_value = {"scenario_id": "scenario-1"}
        scenario_manager = Mock()
        scenario_manager.get_scenario.return_value = {"name": "Billing", "description": "Double charge."}

        handler = VoiceProxyHandler(agent_manager, scenario_manager)

        azure_conn = Mock()
        azure_conn.conversation.item.create = AsyncMock()
        azure_conn.response.create = AsyncMock()

        event = Mock()
        event.call_id = "call-1"
        event.name = "get_scenario_context"
        event.arguments = ""

        await handler._handle_function_call(azure_conn, event, "agent-1")

        azure_conn.conversation.item.create.assert_awaited_once()
        azure_conn.response.create.assert_awaited_once()
        sent_item = azure_conn.conversation.item.create.call_args.kwargs["item"]
        assert sent_item.call_id == "call-1"
        assert "Billing" in sent_item.output

    @pytest.mark.asyncio
    async def test_handle_function_call_skips_when_missing_identifiers(self):
        """A malformed function-call event is ignored without calling Azure."""
        handler = VoiceProxyHandler(Mock(), Mock())

        azure_conn = Mock()
        azure_conn.conversation.item.create = AsyncMock()
        azure_conn.response.create = AsyncMock()

        event = Mock()
        event.call_id = None
        event.name = None
        event.arguments = ""

        await handler._handle_function_call(azure_conn, event, "agent-1")

        azure_conn.conversation.item.create.assert_not_awaited()
        azure_conn.response.create.assert_not_awaited()
