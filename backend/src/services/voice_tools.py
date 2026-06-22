# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Realtime function/tool calling for Voice Live sessions.

This module defines the function tools that are advertised to the realtime model
and the dispatch logic that resolves a tool call against backend scenario data.

The dispatch function is intentionally pure (no WebSocket or SDK objects) so it can
be unit tested in isolation. The WebSocket handler wires the result back to Azure
via ``conversation.item.create`` + ``response.create``.
"""

import json
import logging
from typing import Any, Dict, List, Optional, Protocol

from azure.ai.voicelive.models import FunctionTool

logger = logging.getLogger(__name__)

# Tool names are part of the wire contract with the model. Keep them stable.
GET_SCENARIO_CONTEXT = "get_scenario_context"


class ScenarioLookup(Protocol):
    """Minimal interface the dispatcher needs from a scenario manager."""

    def get_scenario(self, scenario_id: str) -> Optional[Dict[str, Any]]:  # pragma: no cover - protocol
        ...


def build_function_tools() -> List[FunctionTool]:
    """Return the list of function tools advertised to the realtime model.

    Today this is a single read-only tool that lets the model re-ground itself
    on the active scenario. The list is the single place to register new tools.
    """
    return [
        FunctionTool(
            name=GET_SCENARIO_CONTEXT,
            description=(
                "Look up the title and context of the customer-service scenario the "
                "current role-play is based on. Call this if you lose track of who you "
                "are playing or what the situation is. Returns scenario name and a short "
                "context description. Does not take any arguments."
            ),
            parameters={
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            },
        )
    ]


def dispatch_tool_call(
    name: str,
    arguments: str,
    scenario_manager: Optional[ScenarioLookup],
    agent_config: Optional[Dict[str, Any]],
) -> Dict[str, Any]:
    """Resolve a single function call and return a JSON-serializable result dict.

    Args:
        name: The function name requested by the model.
        arguments: The raw JSON-string arguments from the model (may be empty).
        scenario_manager: Object exposing ``get_scenario(scenario_id)``.
        agent_config: The active agent configuration (carries ``scenario_id``).

    Returns:
        A dict that is always JSON-serializable. On failure it contains an
        ``error`` key rather than raising, so the realtime turn can continue.
    """
    parsed_args = _parse_arguments(arguments)

    if name == GET_SCENARIO_CONTEXT:
        return _get_scenario_context(scenario_manager, agent_config)

    logger.warning("Unknown realtime tool requested: %s", name)
    return {"error": f"Unknown tool: {name}", "arguments": parsed_args}


def _parse_arguments(arguments: str) -> Dict[str, Any]:
    """Parse the model-supplied JSON arguments, tolerating empty or invalid input."""
    if not arguments:
        return {}
    try:
        parsed = json.loads(arguments)
        return parsed if isinstance(parsed, dict) else {"value": parsed}
    except (ValueError, TypeError):
        logger.warning("Could not parse tool arguments as JSON: %s", arguments)
        return {}


def _get_scenario_context(
    scenario_manager: Optional[ScenarioLookup],
    agent_config: Optional[Dict[str, Any]],
) -> Dict[str, Any]:
    """Return the active scenario's name and description from backend data."""
    if not agent_config:
        return {"error": "No active scenario for this session."}

    scenario_id = agent_config.get("scenario_id")
    if not scenario_id:
        return {"error": "No active scenario for this session."}

    if scenario_manager is None:
        return {"error": "Scenario lookup is not available."}

    try:
        scenario = scenario_manager.get_scenario(scenario_id)
    except Exception as error:  # noqa: BLE001 - never let a backend failure kill the live turn
        logger.error("Scenario lookup failed for '%s': %s", scenario_id, error)
        return {"error": "Scenario lookup failed."}

    if not scenario:
        return {"error": f"Scenario '{scenario_id}' was not found."}

    return {
        "scenario_id": scenario_id,
        "name": scenario.get("name", ""),
        "description": scenario.get("description", ""),
    }
