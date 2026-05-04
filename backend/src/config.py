# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Configuration management for the upskilling agent application."""

import logging
import os
import time
from typing import Any, Dict

from azure.appconfiguration import AzureAppConfigurationClient
from azure.core.exceptions import AzureError, ClientAuthenticationError
from azure.identity import CredentialUnavailableError, DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()

# Default values as constants
DEFAULT_PORT = 8000
DEFAULT_HOST = "0.0.0.0"
DEFAULT_REGION = "swedencentral"
DEFAULT_MODEL = "gpt-4o"
DEFAULT_API_VERSION = "2024-12-01-preview"
DEFAULT_SPEECH_LANGUAGE = "en-US"
DEFAULT_INPUT_TRANSCRIPTION_MODEL = "azure-speech"
DEFAULT_INPUT_NOISE_REDUCTION_TYPE = "azure_deep_noise_suppression"
DEFAULT_VOICE_NAME = "en-US-Ava:DragonHDLatestNeural"
DEFAULT_VOICE_TYPE = "azure-standard"
DEFAULT_AVATAR_CHARACTER = "lisa"
DEFAULT_AVATAR_STYLE = "casual-sitting"

# Cosmos DB defaults
DEFAULT_COSMOS_DATABASE = "voicelab"
DEFAULT_COSMOS_CONTAINER = "conversations"

# Bounded retry settings for App Configuration load. The first call is when
# DefaultAzureCredential mints a token, so transient IMDS / network glitches
# manifest here. Bounded so a permanently-broken IMDS still fails fast.
_APP_CONFIG_RETRY_ATTEMPTS = 3
_APP_CONFIG_RETRY_BACKOFF_SECONDS = (1, 3, 9)

# Auth/IMDS failure fingerprints (see services/managers.py for rationale).
_AUTH_ERROR_FINGERPRINTS = (
    "imds",
    "invalid_scope",
    "managedidentitycredential",
    "defaultazurecredential",
    "credentialunavailable",
    "failed to retrieve token",
    "no credential in this chain",
)


def _looks_like_auth_error(error: BaseException) -> bool:
    """Heuristic to tag an SDK error as an auth/IMDS failure."""
    if isinstance(error, (ClientAuthenticationError, CredentialUnavailableError)):
        return True
    msg = str(error).lower()
    return any(fp in msg for fp in _AUTH_ERROR_FINGERPRINTS)


logger = logging.getLogger(__name__)


class Config:
    """Application configuration class."""

    def __init__(self):
        """Initialize configuration from environment variables."""
        self._config = self._load_config()

    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from environment variables with defaults."""
        app_config_values = self._load_app_configuration_values()

        azure_ai_region = self._get_setting(
            env_var="AZURE_AI_REGION",
            app_config=app_config_values,
            app_config_key="LOCATION",
            default=DEFAULT_REGION,
        )

        azure_ai_resource_name = self._get_setting(
            env_var="AZURE_AI_RESOURCE_NAME",
            app_config=app_config_values,
            app_config_key="AI_FOUNDRY_ACCOUNT_NAME",
            default="",
        )

        azure_openai_endpoint = self._get_setting(
            env_var="AZURE_OPENAI_ENDPOINT",
            app_config=app_config_values,
            app_config_key="AI_FOUNDRY_ACCOUNT_ENDPOINT",
            default="",
        )

        if not azure_ai_resource_name and azure_openai_endpoint:
            azure_ai_resource_name = self._extract_resource_name_from_endpoint(azure_openai_endpoint)

        realtime_azure_ai_resource_name = self._get_setting(
            env_var="REALTIME_AZURE_AI_RESOURCE_NAME",
            app_config=app_config_values,
            app_config_key="REALTIME_AI_FOUNDRY_ACCOUNT_NAME",
            default=azure_ai_resource_name,
        )

        speech_endpoint = self._get_setting(
            env_var="AZURE_SPEECH_ENDPOINT",
            app_config=app_config_values,
            app_config_key="AZURE_SPEECH_ENDPOINT",
            default=azure_openai_endpoint,
        )

        result: Dict[str, Any] = {
            "azure_ai_resource_name": azure_ai_resource_name,
            "realtime_azure_ai_resource_name": realtime_azure_ai_resource_name,
            "azure_ai_region": azure_ai_region,
            "azure_ai_project_name": self._get_setting(
                env_var="AZURE_AI_PROJECT_NAME",
                app_config=app_config_values,
                app_config_key="AI_FOUNDRY_PROJECT_NAME",
                default="",
            ),
            "project_endpoint": self._get_setting(
                env_var="PROJECT_ENDPOINT",
                app_config=app_config_values,
                app_config_key="AI_FOUNDRY_PROJECT_ENDPOINT",
                default="",
            ),
            "use_azure_ai_agents": self._parse_bool_value(
                self._get_setting(
                    env_var="USE_AZURE_AI_AGENTS",
                    app_config=app_config_values,
                    app_config_key="USE_AZURE_AI_AGENTS",
                    default="false",
                )
            ),
            "agent_id": self._get_setting(
                env_var="AGENT_ID",
                app_config=app_config_values,
                app_config_key="AGENT_ID",
                default="",
            ),
            "port": int(os.getenv("PORT", str(DEFAULT_PORT))),
            "host": os.getenv("HOST", DEFAULT_HOST),
            "azure_openai_endpoint": azure_openai_endpoint,
            "azure_openai_api_key": self._get_setting(
                env_var="AZURE_OPENAI_API_KEY",
                app_config=app_config_values,
                app_config_key="AZURE_OPENAI_API_KEY",
                default="",
            ),
            "model_deployment_name": self._get_setting(
                env_var="MODEL_DEPLOYMENT_NAME",
                app_config=app_config_values,
                app_config_key="CHAT_DEPLOYMENT_NAME",
                default=DEFAULT_MODEL,
            ),
            "realtime_model_deployment_name": self._get_setting(
                env_var="REALTIME_MODEL_DEPLOYMENT_NAME",
                app_config=app_config_values,
                app_config_key="REALTIME_DEPLOYMENT_NAME",
                default="gpt-realtime",
            ),
            "subscription_id": self._get_setting(
                env_var="SUBSCRIPTION_ID",
                app_config=app_config_values,
                app_config_key="SUBSCRIPTION_ID",
                default="",
            ),
            "resource_group_name": self._get_setting(
                env_var="RESOURCE_GROUP_NAME",
                app_config=app_config_values,
                app_config_key="AZURE_RESOURCE_GROUP",
                default="",
            ),
            "azure_speech_key": self._get_setting(
                env_var="AZURE_SPEECH_KEY",
                app_config=app_config_values,
                app_config_key="AZURE_SPEECH_KEY",
                default=self._get_setting(
                    env_var="AZURE_OPENAI_API_KEY",
                    app_config=app_config_values,
                    app_config_key="AZURE_OPENAI_API_KEY",
                    default="",
                ),
            ),
            "azure_speech_endpoint": speech_endpoint,
            "azure_speech_region": self._get_setting(
                env_var="AZURE_SPEECH_REGION",
                app_config=app_config_values,
                app_config_key="AZURE_SPEECH_REGION",
                default=azure_ai_region,
            ),
            "azure_speech_language": self._get_setting(
                env_var="AZURE_SPEECH_LANGUAGE",
                app_config=app_config_values,
                app_config_key="AZURE_SPEECH_LANGUAGE",
                default=DEFAULT_SPEECH_LANGUAGE,
            ),
            "api_version": DEFAULT_API_VERSION,
            "azure_input_transcription_model": self._get_setting(
                env_var="AZURE_INPUT_TRANSCRIPTION_MODEL",
                app_config=app_config_values,
                app_config_key="AZURE_INPUT_TRANSCRIPTION_MODEL",
                default=DEFAULT_INPUT_TRANSCRIPTION_MODEL,
            ),
            "azure_input_transcription_language": self._get_setting(
                env_var="AZURE_INPUT_TRANSCRIPTION_LANGUAGE",
                app_config=app_config_values,
                app_config_key="AZURE_INPUT_TRANSCRIPTION_LANGUAGE",
                default=DEFAULT_SPEECH_LANGUAGE,
            ),
            "azure_input_noise_reduction_type": self._get_setting(
                env_var="AZURE_INPUT_NOISE_REDUCTION_TYPE",
                app_config=app_config_values,
                app_config_key="AZURE_INPUT_NOISE_REDUCTION_TYPE",
                default=DEFAULT_INPUT_NOISE_REDUCTION_TYPE,
            ),
            "azure_voice_name": self._get_setting(
                env_var="AZURE_VOICE_NAME",
                app_config=app_config_values,
                app_config_key="AZURE_VOICE_NAME",
                default=DEFAULT_VOICE_NAME,
            ),
            "azure_voice_type": self._get_setting(
                env_var="AZURE_VOICE_TYPE",
                app_config=app_config_values,
                app_config_key="AZURE_VOICE_TYPE",
                default=DEFAULT_VOICE_TYPE,
            ),
            "azure_avatar_character": self._get_setting(
                env_var="AZURE_AVATAR_CHARACTER",
                app_config=app_config_values,
                app_config_key="AZURE_AVATAR_CHARACTER",
                default=DEFAULT_AVATAR_CHARACTER,
            ),
            "azure_avatar_style": self._get_setting(
                env_var="AZURE_AVATAR_STYLE",
                app_config=app_config_values,
                app_config_key="AZURE_AVATAR_STYLE",
                default=DEFAULT_AVATAR_STYLE,
            ),
            "cosmos_endpoint": self._get_setting(
                env_var="COSMOS_ENDPOINT",
                app_config=app_config_values,
                app_config_key="COSMOS_DB_ENDPOINT",
                default="",
            ),
            "cosmos_database_name": self._get_setting(
                env_var="COSMOS_DATABASE_NAME",
                app_config=app_config_values,
                app_config_key="DATABASE_NAME",
                default="",
            ),
            "cosmos_scenarios_container": self._get_setting(
                env_var="COSMOS_SCENARIOS_CONTAINER",
                app_config=app_config_values,
                app_config_key="SCENARIOS_DATABASE_CONTAINER",
                default="scenarios",
            ),
            "cosmos_rubrics_container": self._get_setting(
                env_var="COSMOS_RUBRICS_CONTAINER",
                app_config=app_config_values,
                app_config_key="RUBRICS_DATABASE_CONTAINER",
                default="rubrics",
            ),
            "cosmos_conversations_container": self._get_setting(
                env_var="COSMOS_CONVERSATIONS_CONTAINER",
                app_config=app_config_values,
                app_config_key="CONVERSATIONS_DATABASE_CONTAINER",
                default="conversations",
            ),
            "cosmos_role_assignments_container": self._get_setting(
                env_var="COSMOS_ROLE_ASSIGNMENTS_CONTAINER",
                app_config=app_config_values,
                app_config_key="ROLE_ASSIGNMENTS_DATABASE_CONTAINER",
                default="role_assignments",
            ),
            "app_display_name": self._get_setting(
                env_var="APP_DISPLAY_NAME",
                app_config=app_config_values,
                app_config_key="APP_DISPLAY_NAME",
                default="Live Voice Practice",
            ),
            "azure_search_endpoint": self._get_setting(
                env_var="AZURE_SEARCH_ENDPOINT",
                app_config=app_config_values,
                app_config_key="AZURE_SEARCH_ENDPOINT",
                default="",
            ),
            "azure_search_index": self._get_setting(
                env_var="AZURE_SEARCH_INDEX",
                app_config=app_config_values,
                app_config_key="AZURE_SEARCH_INDEX",
                default="support-materials",
            ),
            "azure_search_embedding_deployment": self._get_setting(
                env_var="AZURE_SEARCH_EMBEDDING_DEPLOYMENT",
                app_config=app_config_values,
                app_config_key="AZURE_SEARCH_EMBEDDING_DEPLOYMENT",
                default="text-embedding-3-small",
            ),
        }
        return result

    def _load_app_configuration_values(self) -> Dict[str, str]:
        """Load key-values from Azure App Configuration when endpoint is available.

        Performs bounded retries on transient auth/IMDS failures so genuine
        flakiness doesn't permanently degrade the app, while still failing
        fast when IMDS is durably broken.
        """
        endpoint = os.getenv("APP_CONFIG_ENDPOINT", "")
        if not endpoint:
            return {}

        label = os.getenv("APP_CONFIG_LABEL", "live-voice-practice")
        values: Dict[str, str] = {}

        for attempt in range(_APP_CONFIG_RETRY_ATTEMPTS):
            try:
                client = AzureAppConfigurationClient(base_url=endpoint, credential=DefaultAzureCredential())

                for setting in client.list_configuration_settings(label_filter=label):
                    if setting.value is not None:
                        values[setting.key] = setting.value

                if not values:
                    for setting in client.list_configuration_settings():
                        if setting.value is not None:
                            values[setting.key] = setting.value

                logger.info("Loaded %s settings from Azure App Configuration", len(values))
                return values
            except (AzureError, ClientAuthenticationError, CredentialUnavailableError) as error:
                is_auth = _looks_like_auth_error(error)
                if is_auth and attempt < _APP_CONFIG_RETRY_ATTEMPTS - 1:
                    backoff = _APP_CONFIG_RETRY_BACKOFF_SECONDS[attempt]
                    logger.warning(
                        "App Configuration auth/IMDS error on attempt %s/%s, retrying in %ss: %s",
                        attempt + 1,
                        _APP_CONFIG_RETRY_ATTEMPTS,
                        backoff,
                        error,
                    )
                    time.sleep(backoff)
                    continue
                if is_auth:
                    logger.error(
                        "Failed to load App Configuration values due to credential/IMDS error "
                        "after %s attempts: %s. See docs/troubleshooting-imds.md.",
                        _APP_CONFIG_RETRY_ATTEMPTS,
                        error,
                    )
                else:
                    logger.warning("Failed to load App Configuration values: %s", error)
                return {}

        return values

    def _get_setting(self, env_var: str, app_config: Dict[str, str], app_config_key: str, default: str) -> str:
        """Get setting preferring environment variables, then App Configuration, then default."""
        env_value = os.getenv(env_var)
        if env_value is not None and env_value != "":
            return env_value

        app_value = app_config.get(app_config_key)
        if app_value is not None and app_value != "":
            return app_value

        return default

    def _extract_resource_name_from_endpoint(self, endpoint: str) -> str:
        """Extract Azure resource name from endpoint host."""
        try:
            host = endpoint.replace("https://", "").split("/")[0]
            return host.split(".")[0]
        except Exception:
            return ""

    def _parse_bool_value(self, value: str) -> bool:
        """Parse boolean-like values from string."""
        return str(value).strip().lower() in {"1", "true", "yes", "y", "t"}

    def _parse_bool_env(self, env_var: str, default: bool = False) -> bool:
        """Parse boolean environment variable."""
        return os.getenv(env_var, str(default)).lower() == "true"

    def __getitem__(self, key: str) -> Any:
        """Get configuration value by key."""
        return self._config.get(key)

    def get(self, key: str, default: Any = None) -> Any:
        """Get configuration value with optional default."""
        return self._config.get(key, default)

    @property
    def as_dict(self) -> Dict[str, Any]:
        """Return configuration as dictionary."""
        return self._config.copy()


config = Config()
