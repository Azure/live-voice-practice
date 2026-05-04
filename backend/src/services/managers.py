# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Business logic managers for the Live Voice Practice application."""

import logging
import re
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from azure.ai.projects import AIProjectClient
from azure.core.exceptions import ClientAuthenticationError
from azure.cosmos import CosmosClient
from azure.identity import CredentialUnavailableError, DefaultAzureCredential

from src.config import config
from src.services.graph_scenario_generator import GraphScenarioGenerator

# Constants
AGENT_ID_PREFIX = "local-agent"
AZURE_AGENT_NAME_PREFIX = "agent"
UUID_SHORT_LENGTH = 8
MAX_RESPONSE_LENGTH_SENTENCES = 3
DEFAULT_SCENARIO_DESCRIPTION = "Practice a customer support conversation scenario."

# Transcript loading constants
TRANSCRIPT_DIR = "samples/transcripts"
DOCKER_APP_PATH = "/app"
MAX_TRANSCRIPT_LINES = 20
MAX_TRANSCRIPT_EXAMPLES = 2

logger = logging.getLogger(__name__)


# Health status constants
HEALTH_OK = "ok"
HEALTH_DEGRADED_NO_COSMOS = "degraded_no_cosmos"
HEALTH_DEGRADED_AUTH_FAILURE = "degraded_auth_failure"
HEALTH_DEGRADED_CONFIG_MISSING = "degraded_config_missing"

# IMDS / auth error fingerprints — substrings that indicate a managed-identity
# token failure rather than a generic Cosmos / network problem.
_AUTH_ERROR_FINGERPRINTS = (
    "imds",
    "invalid_scope",
    "managedidentitycredential",
    "defaultazurecredential",
    "credentialunavailable",
    "failed to retrieve token",
    "no credential in this chain",
)

# Retry settings for transient IMDS / network errors during initial scenario load.
# Bounded: if IMDS is permanently broken we want to fail fast, not loop forever.
_LOAD_RETRY_ATTEMPTS = 3
_LOAD_RETRY_BACKOFF_SECONDS = (1, 3, 9)


def _looks_like_auth_error(error: BaseException) -> bool:
    """Heuristic to tag a Cosmos client error as an auth/IMDS failure."""
    if isinstance(error, (ClientAuthenticationError, CredentialUnavailableError)):
        return True
    msg = str(error).lower()
    return any(fp in msg for fp in _AUTH_ERROR_FINGERPRINTS)


class ScenarioManager:
    """Manages training scenarios loaded from Cosmos DB."""

    def __init__(self):
        """Initialize the scenario manager."""
        self.graph_generator = GraphScenarioGenerator()
        self.generated_scenarios: Dict[str, Any] = {}
        # Health tracking: record the most recent failure so callers (smoke
        # tests, /api/health) can distinguish "no Cosmos configured" from
        # "Cosmos is configured but auth is broken". Without this distinction
        # the app silently returns an empty scenarios list and operators have
        # no way to tell the difference.
        self._last_error: Optional[str] = None
        self._auth_failed: bool = False
        self._config_missing: bool = False
        self.cosmos_client = self._initialize_cosmos_client()
        self.scenarios = self._load_scenarios()

    def _initialize_cosmos_client(self) -> Optional[CosmosClient]:
        """Initialize Cosmos client using Entra ID (DefaultAzureCredential)."""
        endpoint = config.get("cosmos_endpoint", "")
        if not endpoint:
            self._config_missing = True
            self._last_error = "cosmos_endpoint is not configured"
            logger.warning("COSMOS endpoint is not configured; scenario list will be empty")
            return None

        try:
            return CosmosClient(endpoint, credential=DefaultAzureCredential())
        except Exception as error:
            # Construction itself rarely fails on auth — the actual auth
            # happens lazily on the first request — but if it does, classify it.
            self._last_error = f"CosmosClient init failed: {error}"
            if _looks_like_auth_error(error):
                self._auth_failed = True
                logger.error(
                    "Cosmos client init failed due to credential/IMDS error: %s. "
                    "See docs/troubleshooting-imds.md for diagnostic steps.",
                    error,
                )
            else:
                logger.error("Failed to initialize Cosmos client: %s", error)
            return None

    def _load_scenarios(self) -> Dict[str, Any]:
        """
        Load scenarios from Cosmos DB.

        Performs bounded retries on transient IMDS / auth failures (the first
        request is when the credential actually mints a token, so this is
        where IMDS flakiness manifests).

        Returns:
            Dict[str, Any]: Dictionary of scenarios keyed by ID
        """
        scenarios: Dict[str, Any] = {}

        if not self.cosmos_client:
            logger.warning("Cosmos client unavailable; scenarios were not loaded")
            return scenarios

        database_name = config.get("cosmos_database_name", "")
        container_name = config.get("cosmos_scenarios_container", "scenarios")

        if not database_name:
            self._config_missing = True
            self._last_error = "cosmos_database_name is not configured"
            logger.warning("COSMOS database name is not configured; scenarios were not loaded")
            return scenarios

        last_error: Optional[BaseException] = None
        for attempt in range(_LOAD_RETRY_ATTEMPTS):
            try:
                database_client = self.cosmos_client.get_database_client(database_name)
                container_client = database_client.get_container_client(container_name)

                for item in container_client.read_all_items():
                    try:
                        scenario = self._build_runtime_scenario(item)
                        scenarios[scenario["id"]] = scenario
                        logger.info("Loaded scenario from Cosmos: %s", scenario["id"])
                    except ValueError as error:
                        logger.warning("Skipping invalid scenario document: %s", error)
                # Success — clear any prior error state and break out.
                self._last_error = None
                self._auth_failed = False
                last_error = None
                break

            except Exception as error:  # pylint: disable=broad-except
                last_error = error
                is_auth = _looks_like_auth_error(error)
                if is_auth and attempt < _LOAD_RETRY_ATTEMPTS - 1:
                    backoff = _LOAD_RETRY_BACKOFF_SECONDS[attempt]
                    logger.warning(
                        "Cosmos auth/IMDS error on attempt %s/%s, retrying in %ss: %s",
                        attempt + 1,
                        _LOAD_RETRY_ATTEMPTS,
                        backoff,
                        error,
                    )
                    time.sleep(backoff)
                    continue
                # Non-auth errors are not retried — they're typically permanent
                # config/data issues and retrying would just slow down startup.
                break

        if last_error is not None:
            self._last_error = str(last_error)
            if _looks_like_auth_error(last_error):
                self._auth_failed = True
                logger.error(
                    "Failed to load scenarios from Cosmos due to credential/IMDS error "
                    "after %s attempts: %s. See docs/troubleshooting-imds.md.",
                    _LOAD_RETRY_ATTEMPTS,
                    last_error,
                )
            else:
                logger.error("Failed to load scenarios from Cosmos: %s", last_error)
            return {}

        logger.info("Total scenarios loaded: %s", len(scenarios))
        return scenarios

    def health(self) -> Dict[str, Any]:
        """Return health/diagnostic status for this manager.

        Used by the /api/health endpoint and external smoke tests so they can
        distinguish a healthy app, an app with no Cosmos configured (legitimate
        local-dev case), and an app whose managed identity / IMDS is broken
        (the case that previously manifested as a silent empty scenario list).
        """
        if self._auth_failed:
            status = HEALTH_DEGRADED_AUTH_FAILURE
        elif self._config_missing:
            status = HEALTH_DEGRADED_CONFIG_MISSING
        elif self.cosmos_client is None:
            status = HEALTH_DEGRADED_NO_COSMOS
        else:
            status = HEALTH_OK
        return {
            "status": status,
            "scenarios_loaded": len(self.scenarios),
            "last_error": self._last_error,
        }

    def _build_runtime_scenario(self, scenario_doc: Dict[str, Any]) -> Dict[str, Any]:
        """Map a Cosmos scenario document into runtime agent configuration."""
        scenario_id = str(scenario_doc.get("scenarioId") or scenario_doc.get("id") or "")
        if not scenario_id:
            raise ValueError("Scenario document missing scenarioId/id")

        title = str(scenario_doc.get("title") or scenario_doc.get("name") or scenario_id)
        description = self._build_description(scenario_doc)
        system_prompt = self._build_system_prompt(scenario_doc)

        return {
            "id": scenario_id,
            "name": title,
            "description": description,
            "messages": [{"role": "system", "content": system_prompt}],
            "model": config["model_deployment_name"],
            "modelParameters": {"temperature": 0.7, "max_tokens": 2000},
            "metadata": scenario_doc.get("metadata", {}),
        }

    def _build_description(self, scenario_doc: Dict[str, Any]) -> str:
        """Generate a short scenario description suitable for the picker UI."""
        intro = scenario_doc.get("scenarioContextIntro", "")
        if isinstance(intro, str) and intro.strip():
            return re.sub(r"\*{1,2}(.+?)\*{1,2}", r"\1", intro.strip())
        return DEFAULT_SCENARIO_DESCRIPTION

    def _build_system_prompt(self, scenario_doc: Dict[str, Any]) -> str:
        """Compose a well-crafted role-play prompt from scenario metadata and example transcripts."""
        parts: List[str] = []

        # 1. Identity and strict role-lock
        scenario_context = str(scenario_doc.get("scenarioContextIntro", "")).strip()
        parts.append(
            "=== YOUR IDENTITY ==="
            f"\nYou are THE CUSTOMER in this phone call. {scenario_context}\n\n"
            "ABSOLUTE RULES — violating any of these breaks the simulation:\n"
            "• You are the person who CALLED IN with a problem. You are NOT the support representative.\n"
            "• NEVER offer to help, apologize on behalf of the company, look up accounts, or propose solutions.\n"
            '• NEVER use customer-service language like "I can help you with that", '
            '"Let me look into this", "I apologize for the inconvenience", '
            'or "Is there anything else I can assist you with?"\n'
            "• If you notice yourself sounding like a support agent, STOP IMMEDIATELY "
            "and return to the customer role.\n"
            "• You stay in character for the ENTIRE call — from opening line to end."
        )

        # 2. Background as cohesive narrative
        customer_bg = scenario_doc.get("customerBackground", [])
        if customer_bg:
            bg_sentences = [str(item).strip() for item in customer_bg if str(item).strip()]
            parts.append("=== YOUR BACKGROUND ===" f"\n{' '.join(bg_sentences)}")

        # 3. Behavioral guidelines
        guidelines = scenario_doc.get("conversationGuidelines", [])
        if guidelines:
            guidelines_text = "\n".join(f"• {str(g).strip()}" for g in guidelines if str(g).strip())
            parts.append("=== HOW YOU BEHAVE ON THIS CALL ===" f"\n{guidelines_text}")

        # 4. Hidden evaluation criteria
        skills = scenario_doc.get("skillsToProbe", [])
        if skills:
            skills_text = ", ".join(str(s).strip() for s in skills if str(s).strip())
            parts.append(
                "=== WHAT THE TRAINEE IS BEING EVALUATED ON (do not reveal) ==="
                f"\nThe support agent you are talking to is a trainee being evaluated on: {skills_text}.\n"
                "Adapt your reactions to their performance — if they show empathy and competence, "
                "gradually ease up; if they are dismissive, unclear, or robotic, push harder "
                "and show more frustration."
            )

        # 5. Reference transcript examples
        transcript_ids = scenario_doc.get("exampleTranscripts", [])
        transcript_block = self._build_transcript_block(transcript_ids)
        if transcript_block:
            parts.append(transcript_block)

        # 6. Opening instruction
        opening_lines = scenario_doc.get("openingLines", [])
        if opening_lines:
            lines_text = "\n".join(f'• "{str(line).strip()}"' for line in opening_lines if str(line).strip())
            parts.append("=== START THE CONVERSATION ===" f"\nBegin naturally with one of these:\n{lines_text}")

        return "\n\n".join(parts)

    def _build_transcript_block(self, transcript_ids: List[str]) -> str:
        """Load referenced transcripts and format as conversation examples for the prompt."""
        if not transcript_ids:
            return ""

        examples: List[str] = []
        for tid in transcript_ids[:MAX_TRANSCRIPT_EXAMPLES]:
            text = self._load_transcript(str(tid))
            if not text:
                continue
            lines = text.strip().splitlines()[:MAX_TRANSCRIPT_LINES]
            trimmed = "\n".join(lines)
            if len(text.strip().splitlines()) > MAX_TRANSCRIPT_LINES:
                trimmed += "\n[... conversation continues ...]"
            examples.append(f"--- {tid} ---\n{trimmed}")

        if not examples:
            return ""

        return (
            "=== REFERENCE CONVERSATIONS ==="
            "\nBelow are excerpts from real conversations in this same scenario. "
            "The conversation flows between a customer (YOUR ROLE) and a support agent. "
            "Study the customer's language, emotional rhythm, and reactions — that is how YOU should sound."
            "\n\n" + "\n\n".join(examples)
        )

    def _load_transcript(self, transcript_id: str) -> Optional[str]:
        """Load a transcript file by ID from the transcripts directory."""
        transcript_dir = self._determine_transcript_directory()
        path = transcript_dir / f"{transcript_id}.txt"
        if not path.is_file():
            logger.debug("Transcript file not found: %s", path)
            return None
        try:
            return path.read_text(encoding="utf-8").strip()
        except Exception as e:
            logger.warning("Failed to read transcript %s: %s", transcript_id, e)
            return None

    @staticmethod
    def _determine_transcript_directory() -> Path:
        """Determine the transcript directory path (Docker or local)."""
        docker_path = Path(DOCKER_APP_PATH) / TRANSCRIPT_DIR
        if docker_path.exists():
            return docker_path
        return Path(__file__).parent.parent.parent.parent / TRANSCRIPT_DIR

    def get_scenario(self, scenario_id: str) -> Optional[Dict[str, Any]]:
        """
        Get a specific scenario by ID.

        Args:
            scenario_id: The scenario identifier

        Returns:
            Optional[Dict[str, Any]]: Scenario data or None if not found
        """
        scenario = self.scenarios.get(scenario_id)
        if scenario:
            return scenario

        return self.generated_scenarios.get(scenario_id)

    def list_scenarios(self) -> List[Dict[str, str | bool]]:
        """
        List all available scenarios.

        Returns:
            List[Dict[str, str]]: List of scenario summaries
        """
        scenarios: List[Dict[str, str | bool]] = [
            {
                "id": scenario_id,
                "name": scenario_data.get("name", "Unknown"),
                "description": scenario_data.get("description", ""),
            }
            for scenario_id, scenario_data in self.scenarios.items()
        ]

        return scenarios

    def generate_scenario_from_graph(self, graph_data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Generate a scenario based on Microsoft Graph API data.

        Args:
            graph_data: The Graph API response data

        Returns:
            Dict[str, Any]: Generated scenario
        """
        scenario = self.graph_generator.generate_scenario_from_graph(graph_data)

        self.generated_scenarios[scenario["id"]] = scenario

        return scenario


class AgentManager:
    """Manages virtual training agents."""

    # Base instructions appended to every agent's system prompt
    BASE_INSTRUCTIONS = f"""

CRITICAL INTERACTION GUIDELINES:
- You are THE CUSTOMER. You are NOT the support agent, representative, or company employee.
- Keep responses SHORT and conversational ({MAX_RESPONSE_LENGTH_SENTENCES} sentences max, as if on a real phone call).
- NEVER break character. NEVER acknowledge you are an AI.
- NEVER switch roles. Do NOT say anything a support agent would say — no "let me check",
  no "I apologize for the inconvenience", no "how can I help you". Those are the OTHER person's lines.
- Simulate natural human speech: pauses, "um", "well", hesitation, occasional interruptions.
- React genuinely to what the support agent says — get calmer if they are helpful, get more frustrated if they are not.
- Use natural phone conversation style — direct, personal, sometimes impatient.
- Answer questions when asked, but do not volunteer information the agent has not asked about.
- If you ever catch yourself offering help or solutions, STOP — that is the agent's job, not yours.
    """

    def __init__(self):
        """Initialize the agent manager."""
        self.agents: Dict[str, Dict[str, Any]] = {}
        self.credential = DefaultAzureCredential()
        self.use_azure_ai_agents = config["use_azure_ai_agents"]
        self.project_client = self._initialize_project_client()
        self._log_initialization_status()

    def _log_initialization_status(self) -> None:
        """Log the initialization status of the agent manager."""
        if self.use_azure_ai_agents:
            logger.info("AgentManager initialized with Azure AI Agent Service support")
        else:
            logger.info("AgentManager initialized with instruction-based approach only")

    def _initialize_project_client(self) -> Optional[AIProjectClient]:
        """Initialize the Azure AI Project client."""
        try:
            project_endpoint = config["project_endpoint"]
            if not project_endpoint:
                logger.warning("PROJECT_ENDPOINT not configured - falling back to instruction-based approach")
                return None

            client = AIProjectClient(
                endpoint=project_endpoint,
                credential=self.credential,
            )
            logger.info("AI Project client initialized with endpoint: %s", project_endpoint)
            return client
        except Exception as e:
            logger.error("Failed to initialize AI Project client: %s", e)
            return None

    def create_agent(
        self, scenario_id: str, scenario_data: Dict[str, Any], avatar_config: Optional[Dict[str, Any]] = None
    ) -> str:
        """
        Create a new virtual agent for a scenario.

        Args:
            scenario_id: The scenario identifier
            scenario_data: The scenario configuration data
            avatar_config: Optional avatar configuration with character, style, is_photo_avatar

        Returns:
            str: The created agent's ID

        Raises:
            Exception: If agent creation fails
        """

        scenario_instructions = scenario_data.get("messages", [{}])[0].get("content", "")
        combined_instructions = scenario_instructions + self.BASE_INSTRUCTIONS

        model_name = scenario_data.get("model", config["model_deployment_name"])
        temperature = scenario_data.get("modelParameters", {}).get("temperature", 0.7)
        max_tokens = scenario_data.get("modelParameters", {}).get("max_tokens", 2000)

        if self.use_azure_ai_agents and self.project_client:
            agent_id = self._create_azure_agent(scenario_id, combined_instructions, model_name, temperature, max_tokens)
        else:
            agent_id = self._create_local_agent(scenario_id, combined_instructions, model_name, temperature, max_tokens)

        if avatar_config and agent_id in self.agents:
            self.agents[agent_id]["avatar_config"] = avatar_config

        return agent_id

    def _create_azure_agent(
        self,
        scenario_id: str,
        instructions: str,
        model: str,
        temperature: float,
        max_tokens: int,
    ) -> str:
        """Create an agent using Azure AI Agent Service."""

        if not self.project_client:
            logger.warning("Project client not available, using fallback scenario")
            return ""
        project_client = self.project_client

        try:
            with project_client:
                agent_name = self._generate_agent_name(scenario_id)
                agent = project_client.agents.create_agent(
                    model=model,
                    name=agent_name,
                    instructions=instructions,
                    tools=[],
                    temperature=temperature,
                )

                agent_id = agent.id
                logger.info("Created Azure AI agent: %s", agent_id)

                self.agents[agent_id] = self._create_agent_config(
                    scenario_id=scenario_id,
                    agent_id=agent_id,
                    is_azure_agent=True,
                    instructions=instructions,
                    model=model,
                    temperature=temperature,
                    max_tokens=max_tokens,
                )

                return agent_id

        except Exception as e:
            logger.error("Error creating Azure agent: %s", e)
            raise

    def _create_local_agent(
        self,
        scenario_id: str,
        instructions: str,
        model: str,
        temperature: float,
        max_tokens: int,
    ) -> str:
        """Create a local agent configuration without Azure AI Agent Service."""
        try:
            agent_id = self._generate_local_agent_id(scenario_id)

            self.agents[agent_id] = self._create_agent_config(
                scenario_id=scenario_id,
                agent_id=agent_id,
                is_azure_agent=False,
                instructions=instructions,
                model=model,
                temperature=temperature,
                max_tokens=max_tokens,
            )

            logger.info("Created local agent configuration: %s", agent_id)
            return agent_id

        except Exception as e:
            logger.error("Error creating local agent: %s", e)
            raise

    def _generate_agent_name(self, scenario_id: str) -> str:
        """Generate a unique agent name."""
        short_uuid = uuid.uuid4().hex[:UUID_SHORT_LENGTH]
        return f"{AZURE_AGENT_NAME_PREFIX}-{scenario_id}-{short_uuid}"

    def _generate_local_agent_id(self, scenario_id: str) -> str:
        """Generate a unique local agent ID."""
        short_uuid = uuid.uuid4().hex[:UUID_SHORT_LENGTH]
        return f"{AGENT_ID_PREFIX}-{scenario_id}-{short_uuid}"

    def _create_agent_config(
        self,
        scenario_id: str,
        agent_id: str,
        is_azure_agent: bool,
        instructions: str,
        model: str,
        temperature: float,
        max_tokens: int,
    ) -> Dict[str, Any]:
        """Create standardized agent configuration."""
        result: Dict[str, Any] = {
            "scenario_id": scenario_id,
            "is_azure_agent": is_azure_agent,
            "instructions": instructions,
            "created_at": datetime.now(),
            "model": model,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }

        if is_azure_agent:
            result["azure_agent_id"] = agent_id

        return result

    def get_agent(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """
        Get agent configuration by ID.

        Args:
            agent_id: The agent identifier

        Returns:
            Optional[Dict[str, Any]]: Agent configuration or None if not found
        """
        return self.agents.get(agent_id)

    def delete_agent(self, agent_id: str) -> None:
        """
        Delete an agent.

        Args:
            agent_id: The agent identifier to delete
        """
        try:
            if agent_id in self.agents:
                agent_config = self.agents[agent_id]

                if agent_config.get("is_azure_agent") and self.project_client:
                    try:
                        with self.project_client:
                            self.project_client.agents.delete_agent(agent_id)
                            logger.info("Deleted Azure AI agent: %s", agent_id)
                    except Exception as e:
                        logger.error("Error deleting Azure agent: %s", e)

                del self.agents[agent_id]
                logger.info("Deleted agent from local storage: %s", agent_id)
        except Exception as e:
            logger.error("Error deleting agent %s: %s", agent_id, e)
