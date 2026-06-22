"""Tests for the voice_tools realtime function-calling module."""

from unittest.mock import Mock

from src.services.voice_tools import (
    GET_SCENARIO_CONTEXT,
    build_function_tools,
    dispatch_tool_call,
)


class TestBuildFunctionTools:
    """Test cases for build_function_tools."""

    def test_returns_get_scenario_context_tool(self):
        """The advertised tool list contains the scenario-context tool."""
        tools = build_function_tools()

        assert len(tools) == 1
        assert tools[0].name == GET_SCENARIO_CONTEXT
        assert tools[0].description

    def test_tool_has_object_parameters_schema(self):
        """The tool exposes a valid no-argument JSON schema."""
        tool = build_function_tools()[0]

        assert tool.parameters["type"] == "object"
        assert tool.parameters["properties"] == {}


class TestDispatchToolCall:
    """Test cases for dispatch_tool_call."""

    def _scenario_manager(self, scenario):
        manager = Mock()
        manager.get_scenario.return_value = scenario
        return manager

    def test_get_scenario_context_success(self):
        """A known scenario resolves to name and description."""
        scenario = {"name": "Billing dispute", "description": "Angry customer about a double charge."}
        manager = self._scenario_manager(scenario)
        agent_config = {"scenario_id": "scenario-1"}

        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, "", manager, agent_config)

        assert result["scenario_id"] == "scenario-1"
        assert result["name"] == "Billing dispute"
        assert result["description"] == "Angry customer about a double charge."
        manager.get_scenario.assert_called_once_with("scenario-1")

    def test_get_scenario_context_ignores_extra_arguments(self):
        """Non-empty but irrelevant JSON arguments do not break dispatch."""
        scenario = {"name": "Returns", "description": "Wants a refund."}
        manager = self._scenario_manager(scenario)
        agent_config = {"scenario_id": "scenario-2"}

        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, '{"unused": 1}', manager, agent_config)

        assert result["name"] == "Returns"

    def test_get_scenario_context_handles_invalid_json_arguments(self):
        """Malformed argument strings are tolerated, not raised."""
        scenario = {"name": "Returns", "description": "Wants a refund."}
        manager = self._scenario_manager(scenario)
        agent_config = {"scenario_id": "scenario-2"}

        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, "not-json", manager, agent_config)

        assert result["name"] == "Returns"

    def test_missing_agent_config_returns_error(self):
        """Without an agent config there is no active scenario."""
        manager = self._scenario_manager({"name": "x", "description": "y"})

        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, "", manager, None)

        assert "error" in result
        manager.get_scenario.assert_not_called()

    def test_missing_scenario_id_returns_error(self):
        """An agent config without a scenario_id returns a graceful error."""
        manager = self._scenario_manager({"name": "x", "description": "y"})

        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, "", manager, {})

        assert "error" in result
        manager.get_scenario.assert_not_called()

    def test_missing_scenario_manager_returns_error(self):
        """When no scenario manager is wired, dispatch degrades gracefully."""
        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, "", None, {"scenario_id": "scenario-1"})

        assert "error" in result

    def test_scenario_not_found_returns_error(self):
        """A missing scenario yields an error rather than raising."""
        manager = self._scenario_manager(None)

        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, "", manager, {"scenario_id": "missing"})

        assert "error" in result
        assert "missing" in result["error"]

    def test_unknown_tool_returns_error(self):
        """An unrecognized tool name returns an error dict."""
        manager = self._scenario_manager({"name": "x", "description": "y"})

        result = dispatch_tool_call("does_not_exist", "", manager, {"scenario_id": "scenario-1"})

        assert "error" in result
        assert "Unknown tool" in result["error"]

    def test_scenario_lookup_exception_returns_error(self):
        """A backend failure during lookup is contained, not raised."""
        manager = Mock()
        manager.get_scenario.side_effect = RuntimeError("cosmos down")

        result = dispatch_tool_call(GET_SCENARIO_CONTEXT, "", manager, {"scenario_id": "scenario-1"})

        assert "error" in result
