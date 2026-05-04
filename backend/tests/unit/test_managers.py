"""Tests for the managers module."""

from datetime import datetime
from unittest.mock import MagicMock, Mock, patch

from src.services.managers import AgentManager, ScenarioManager


class TestScenarioManager:
    """Test scenario manager functionality."""

    @patch("src.services.managers.config")
    def test_scenario_manager_without_cosmos_endpoint(self, mock_config):
        """Test scenario manager when Cosmos endpoint is not configured."""
        mock_config.get.side_effect = lambda key, default=None: {
            "cosmos_endpoint": "",
            "cosmos_key": "",
            "cosmos_database_name": "",
            "cosmos_scenarios_container": "scenarios",
        }.get(key, default)
        mock_config.__getitem__.side_effect = lambda key: {
            "model_deployment_name": "gpt-4o",
        }.get(key, "")

        manager = ScenarioManager()
        assert len(manager.scenarios) == 0

    @patch("src.services.managers.CosmosClient")
    @patch("src.services.managers.config")
    def test_scenario_manager_with_valid_scenarios(self, mock_config, mock_cosmos_client):
        """Test scenario manager loading scenarios from Cosmos DB."""
        mock_config.get.side_effect = lambda key, default=None: {
            "cosmos_endpoint": "https://test.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "test-db",
            "cosmos_scenarios_container": "scenarios",
        }.get(key, default)
        mock_config.__getitem__.side_effect = lambda key: {
            "model_deployment_name": "gpt-4o",
        }.get(key, "")

        mock_container = Mock()
        mock_container.read_all_items.return_value = [
            {
                "scenarioId": "contoso-001",
                "title": "Billing Follow-up",
                "scenarioContextIntro": "Customer is frustrated about a billing issue.",
                "customerBackground": ["Long-term customer"],
                "conversationGuidelines": ["Remain frustrated until clarity is provided"],
                "openingLines": ["I still have an unresolved billing charge."],
            }
        ]
        mock_database = Mock()
        mock_database.get_container_client.return_value = mock_container
        mock_client = Mock()
        mock_client.get_database_client.return_value = mock_database
        mock_cosmos_client.return_value = mock_client

        manager = ScenarioManager()
        assert len(manager.scenarios) == 1
        assert "contoso-001" in manager.scenarios

        # Verify the prompt contains role-lock and structured sections
        scenario = manager.scenarios["contoso-001"]
        prompt = scenario["messages"][0]["content"]
        assert "YOUR IDENTITY" in prompt
        assert "THE CUSTOMER" in prompt
        assert "NOT the support representative" in prompt
        assert "Customer is frustrated about a billing issue" in prompt

    @patch("src.services.managers.CosmosClient")
    @patch("src.services.managers.config")
    def test_build_system_prompt_contains_all_sections(self, mock_config, mock_cosmos_client):
        """Test that the generated prompt includes all structured sections."""
        mock_config.get.side_effect = lambda key, default=None: {
            "cosmos_endpoint": "https://test.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "test-db",
            "cosmos_scenarios_container": "scenarios",
        }.get(key, default)
        mock_config.__getitem__.side_effect = lambda key: {
            "model_deployment_name": "gpt-4o",
        }.get(key, "")

        mock_container = Mock()
        mock_container.read_all_items.return_value = [
            {
                "scenarioId": "test-prompt",
                "title": "Test Prompt Scenario",
                "scenarioContextIntro": "You are upset about a late delivery.",
                "customerBackground": ["Ordered two weeks ago.", "First-time buyer."],
                "conversationGuidelines": ["Be impatient.", "Demand a refund."],
                "openingLines": ["Where is my package?"],
                "skillsToProbe": ["Empathy", "Timeliness"],
            }
        ]
        mock_database = Mock()
        mock_database.get_container_client.return_value = mock_container
        mock_client = Mock()
        mock_client.get_database_client.return_value = mock_database
        mock_cosmos_client.return_value = mock_client

        manager = ScenarioManager()
        prompt = manager.scenarios["test-prompt"]["messages"][0]["content"]

        # Identity and role-lock
        assert "YOUR IDENTITY" in prompt
        assert "NOT the support representative" in prompt
        assert "NEVER use customer-service language" in prompt
        # Background as narrative
        assert "YOUR BACKGROUND" in prompt
        assert "Ordered two weeks ago. First-time buyer." in prompt
        # Behavioral guidelines
        assert "HOW YOU BEHAVE" in prompt
        assert "Be impatient" in prompt
        assert "Demand a refund" in prompt
        # Skills evaluation
        assert "TRAINEE IS BEING EVALUATED" in prompt
        assert "Empathy" in prompt
        # Opening instruction
        assert "START THE CONVERSATION" in prompt
        assert "Where is my package?" in prompt

    @patch("src.services.managers.CosmosClient")
    @patch("src.services.managers.config")
    def test_build_system_prompt_includes_transcripts(self, mock_config, mock_cosmos_client):
        """Test that referenced transcripts are loaded and included in the prompt."""
        mock_config.get.side_effect = lambda key, default=None: {
            "cosmos_endpoint": "https://test.documents.azure.com:443/",
            "cosmos_key": "fake-key",
            "cosmos_database_name": "test-db",
            "cosmos_scenarios_container": "scenarios",
        }.get(key, default)
        mock_config.__getitem__.side_effect = lambda key: {
            "model_deployment_name": "gpt-4o",
        }.get(key, "")

        mock_container = Mock()
        mock_container.read_all_items.return_value = [
            {
                "scenarioId": "with-transcripts",
                "title": "Transcript Test",
                "scenarioContextIntro": "Billing issue.",
                "exampleTranscripts": ["transcript-001"],
            }
        ]
        mock_database = Mock()
        mock_database.get_container_client.return_value = mock_container
        mock_client = Mock()
        mock_client.get_database_client.return_value = mock_database
        mock_cosmos_client.return_value = mock_client

        manager = ScenarioManager()
        prompt = manager.scenarios["with-transcripts"]["messages"][0]["content"]

        # The prompt should contain transcript reference section if file exists on disk
        transcript_path = manager._determine_transcript_directory() / "transcript-001.txt"
        if transcript_path.is_file():
            assert "REFERENCE CONVERSATIONS" in prompt
            assert "transcript-001" in prompt

    def test_load_transcript_returns_none_for_missing(self):
        """Test that _load_transcript returns None for nonexistent files."""
        manager = ScenarioManager()
        result = manager._load_transcript("nonexistent-transcript")
        assert result is None

    def test_load_transcript_reads_existing_file(self):
        """Test that _load_transcript reads an existing transcript file."""
        manager = ScenarioManager()
        transcript_dir = manager._determine_transcript_directory()
        if (transcript_dir / "transcript-001.txt").is_file():
            result = manager._load_transcript("transcript-001")
            assert result is not None
            assert "charge" in result.lower()

    def test_get_scenario_existing(self):
        """Test getting an existing scenario."""
        manager = ScenarioManager()
        manager.scenarios = {"test": {"name": "Test Scenario"}}

        scenario = manager.get_scenario("test")
        assert scenario is not None
        assert scenario["name"] == "Test Scenario"

    def test_get_scenario_nonexistent(self):
        """Test getting a non-existent scenario."""
        manager = ScenarioManager()
        manager.scenarios = {}

        scenario = manager.get_scenario("nonexistent")
        assert scenario is None

    def test_list_scenarios(self):
        """Test listing scenarios."""
        manager = ScenarioManager()
        manager.scenarios = {
            "scenario1": {"name": "Scenario 1", "description": "First scenario"},
            "scenario2": {"name": "Scenario 2", "description": "Second scenario"},
        }

        scenarios = manager.list_scenarios()
        assert len(scenarios) == 2
        assert scenarios[0]["id"] == "scenario1"
        assert scenarios[1]["id"] == "scenario2"

    @patch("src.services.managers.config")
    def test_health_no_cosmos_when_endpoint_missing(self, mock_config):
        """Health should report degraded_config_missing when no endpoint is set."""
        mock_config.get.side_effect = lambda key, default=None: {
            "cosmos_endpoint": "",
            "cosmos_database_name": "",
            "cosmos_scenarios_container": "scenarios",
        }.get(key, default)
        mock_config.__getitem__.side_effect = lambda key: ""

        manager = ScenarioManager()
        result = manager.health()
        assert result["status"] == "degraded_config_missing"
        assert result["scenarios_loaded"] == 0

    @patch("src.services.managers.CosmosClient")
    @patch("src.services.managers.config")
    def test_health_auth_failure_on_imds_error(self, mock_config, mock_cosmos_client):
        """An IMDS-shaped error during load must surface as degraded_auth_failure."""
        from azure.core.exceptions import ClientAuthenticationError

        mock_config.get.side_effect = lambda key, default=None: {
            "cosmos_endpoint": "https://test.documents.azure.com:443/",
            "cosmos_database_name": "test-db",
            "cosmos_scenarios_container": "scenarios",
        }.get(key, default)
        mock_config.__getitem__.side_effect = lambda key: ""

        client_instance = Mock()
        client_instance.get_database_client.side_effect = ClientAuthenticationError(
            "DefaultAzureCredential failed: ManagedIdentityCredential IMDS invalid_scope"
        )
        mock_cosmos_client.return_value = client_instance

        with patch("src.services.managers.time.sleep"):
            manager = ScenarioManager()

        result = manager.health()
        assert result["status"] == "degraded_auth_failure"
        assert result["scenarios_loaded"] == 0
        assert result["last_error"] is not None


class TestAgentManager:
    """Test cases for AgentManager."""

    def setup_method(self):
        """Set up test fixtures."""
        with patch("src.services.managers.config") as mock_config:
            mock_config.__getitem__.side_effect = lambda key: {
                "use_azure_ai_agents": False,
                "project_endpoint": "",
                "model_deployment_name": "gpt-4o",
            }.get(key, "")
            mock_config.get.side_effect = lambda key, default=None: {
                "use_azure_ai_agents": False,
                "project_endpoint": "",
                "model_deployment_name": "gpt-4o",
            }.get(key, default)
            with patch("src.services.managers.DefaultAzureCredential"):
                self.agent_manager = AgentManager()  # pylint: disable=attribute-defined-outside-init

    @patch("src.services.managers.config")
    def test_create_agent_success_local(self, mock_config):
        """Test successful local agent creation."""
        # Configure for local agent creation (no Azure AI Agents)
        mock_config.__getitem__.side_effect = lambda key: {
            "use_azure_ai_agents": False,
            "model_deployment_name": "gpt-4o",
        }.get(key, "default")

        manager = AgentManager()
        scenario_data = {
            "messages": [{"content": "Test instructions"}],
            "model": "gpt-4",
            "modelParameters": {"temperature": 0.8, "max_tokens": 1500},
        }

        agent_id = manager.create_agent("test-scenario", scenario_data)

        assert agent_id.startswith("local-agent-test-scenario-")
        assert agent_id in manager.agents
        assert manager.agents[agent_id]["scenario_id"] == "test-scenario"
        assert manager.agents[agent_id]["is_azure_agent"] is False
        assert "Test instructions" in manager.agents[agent_id]["instructions"]
        assert manager.BASE_INSTRUCTIONS in manager.agents[agent_id]["instructions"]

    @patch("src.services.managers.config")
    @patch("src.services.managers.AIProjectClient")
    def test_create_agent_success_azure(self, mock_ai_client, mock_config):
        """Test successful Azure agent creation."""
        # Mock configuration
        mock_config.__getitem__.side_effect = lambda key: {
            "use_azure_ai_agents": True,
            "project_endpoint": "https://test.endpoint",
            "model_deployment_name": "gpt-4o",
        }.get(key, "")
        mock_config.get.side_effect = lambda key, default=None: {
            "use_azure_ai_agents": True,
            "project_endpoint": "https://test.endpoint",
            "model_deployment_name": "gpt-4o",
        }.get(key, default)

        # Mock AI Project Client with context manager support
        mock_client_instance = MagicMock()
        mock_client_instance.__enter__ = Mock(return_value=mock_client_instance)
        mock_client_instance.__exit__ = Mock(return_value=None)

        mock_agent = Mock()
        mock_agent.id = "test-azure-agent-id"
        mock_client_instance.agents.create_agent.return_value = mock_agent
        mock_ai_client.return_value = mock_client_instance

        # Create agent manager with Azure AI enabled
        agent_manager = AgentManager()
        agent_manager.project_client = mock_client_instance

        scenario_data = {
            "messages": [{"content": "Test instructions"}],
            "model": "gpt-4o",
            "modelParameters": {"temperature": 0.8, "max_tokens": 1500},
        }

        agent_id = agent_manager.create_agent("test-scenario", scenario_data)

        assert agent_id == "test-azure-agent-id"
        assert agent_id in agent_manager.agents
        agent_config = agent_manager.agents[agent_id]
        assert agent_config["scenario_id"] == "test-scenario"
        assert agent_config["is_azure_agent"] is True
        assert agent_config["model"] == "gpt-4o"
        assert agent_config["temperature"] == 0.8
        assert agent_config["max_tokens"] == 1500

    def test_get_agent_existing(self):
        """Test getting an existing agent."""
        manager = AgentManager()
        test_agent = {"scenario_id": "test", "instructions": "Test"}
        manager.agents["test-agent"] = test_agent

        agent = manager.get_agent("test-agent")
        assert agent == test_agent

    def test_get_agent_nonexistent(self):
        """Test getting a non-existent agent."""
        manager = AgentManager()

        agent = manager.get_agent("nonexistent")
        assert agent is None

    def test_delete_agent_existing(self):
        """Test deleting an existing agent."""
        manager = AgentManager()
        manager.agents["test-agent"] = {"scenario_id": "test"}

        manager.delete_agent("test-agent")
        assert "test-agent" not in manager.agents

    def test_delete_agent_nonexistent(self):
        """Test deleting a non-existent agent (should not raise error)."""
        manager = AgentManager()

        # Should not raise an exception
        manager.delete_agent("nonexistent")
        assert len(manager.agents) == 0

    @patch("src.services.managers.config")
    def test_delete_agent_local(self, mock_config):
        """Test deleting a local agent."""
        mock_config.__getitem__.side_effect = lambda key: {
            "use_azure_ai_agents": False,
            "model_deployment_name": "gpt-4o",
        }.get(key, "default")

        manager = AgentManager()
        manager.agents["test-agent"] = {"scenario_id": "test", "is_azure_agent": False}

        manager.delete_agent("test-agent")
        assert "test-agent" not in manager.agents

    @patch("src.services.managers.config")
    @patch("src.services.managers.AIProjectClient")
    def test_delete_agent_azure(self, mock_ai_client, mock_config):
        """Test Azure agent deletion."""
        # Mock configuration
        mock_config.__getitem__.side_effect = lambda key: {
            "use_azure_ai_agents": True,
            "project_endpoint": "https://test.endpoint",
            "model_deployment_name": "gpt-4o",
        }.get(key, "")
        mock_config.get.side_effect = lambda key, default=None: {
            "use_azure_ai_agents": True,
            "project_endpoint": "https://test.endpoint",
            "model_deployment_name": "gpt-4o",
        }.get(key, default)

        # Mock AI Project Client with context manager support
        mock_client_instance = MagicMock()
        mock_client_instance.__enter__ = Mock(return_value=mock_client_instance)
        mock_client_instance.__exit__ = Mock(return_value=None)
        mock_ai_client.return_value = mock_client_instance

        # Create agent manager
        agent_manager = AgentManager()
        agent_manager.project_client = mock_client_instance

        # Add a test Azure agent
        agent_id = "test-azure-agent"
        agent_manager.agents[agent_id] = {
            "scenario_id": "test-scenario",
            "is_azure_agent": True,
            "instructions": "Test instructions",
            "created_at": datetime.now(),
            "model": "gpt-4o",
            "temperature": 0.7,
            "max_tokens": 2000,
            "azure_agent_id": agent_id,
        }

        # Delete the agent
        agent_manager.delete_agent(agent_id)

        # Verify deletion
        assert agent_id not in agent_manager.agents
        mock_client_instance.agents.delete_agent.assert_called_once_with(agent_id)
        agent_manager.delete_agent(agent_id)

        # Verify deletion
        assert agent_id not in agent_manager.agents
        mock_client_instance.agents.delete_agent.assert_called_once_with(agent_id)
