# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Flask application for Live Voice Practice."""

import asyncio
import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, cast

import simple_websocket.ws  # pyright: ignore[reportMissingTypeStubs]
from flask import Flask, jsonify, request, send_from_directory
from flask_sock import Sock  # pyright: ignore[reportMissingTypeStubs]

from src.services.auth import UserIdentity, get_current_user, require_auth
from src.config import config
from src.services.analyzers import ConversationAnalyzer, PronunciationAssessor
from src.services.conversation_manager import ConversationManager
from src.services.database import conversation_store
from src.services.managers import AgentManager, ScenarioManager
from src.services.websocket_handler import VoiceProxyHandler

# Constants
STATIC_FOLDER = "../static"
STATIC_URL_PATH = ""
INDEX_FILE = "index.html"
AUDIO_PROCESSOR_FILE = "audio-processor.js"
WEBSOCKET_ENDPOINT = "/ws/voice"

# API endpoints
API_CONFIG_ENDPOINT = "/api/config"
API_SCENARIOS_ENDPOINT = "/api/scenarios"
API_AGENTS_CREATE_ENDPOINT = "/api/agents/create"
API_ANALYZE_ENDPOINT = "/api/analyze"
API_CONVERSATIONS_ENDPOINT = "/api/conversations"
API_GRAPH_SCENARIO_ENDPOINT = "/api/scenarios/graph"

# Error messages
SCENARIO_ID_REQUIRED = "scenario_id is required"
SCENARIO_NOT_FOUND = "Scenario not found"
CUSTOM_SCENARIO_NOT_SUPPORTED = "custom_scenario is not supported; provide scenario_id from /api/scenarios"
TRANSCRIPT_REQUIRED = "scenario_id and transcript are required"
ACCESS_DENIED = "Access denied"
CONVERSATION_NOT_FOUND = "Conversation not found"

# HTTP status codes
HTTP_BAD_REQUEST = 400
HTTP_UNAUTHORIZED = 401
HTTP_FORBIDDEN = 403
HTTP_NOT_FOUND = 404
HTTP_INTERNAL_SERVER_ERROR = 500

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize Flask application
app = Flask(__name__, static_folder=STATIC_FOLDER, static_url_path=STATIC_URL_PATH)
sock = Sock(app)

# Initialize managers and analyzers
scenario_manager = ScenarioManager()
agent_manager = AgentManager()
conversation_manager = ConversationManager()
conversation_analyzer = ConversationAnalyzer()
pronunciation_assessor = PronunciationAssessor()
voice_proxy_handler = VoiceProxyHandler(agent_manager)


@app.route("/")
def index():
    """Serve the main application page."""
    if app.static_folder is None:
        logger.error("STATIC_FOLDER is not set. Cannot serve index.html.")
        import sys  # pylint: disable=C0415

        sys.exit(1)
    return send_from_directory(app.static_folder, INDEX_FILE)


@app.route(API_CONFIG_ENDPOINT)
def get_config():
    """Get client configuration."""
    return jsonify({"proxy_enabled": True, "ws_endpoint": WEBSOCKET_ENDPOINT})


@app.route(API_SCENARIOS_ENDPOINT)
def get_scenarios():
    """Get list of available scenarios."""
    return jsonify(scenario_manager.list_scenarios())


@app.route(f"{API_SCENARIOS_ENDPOINT}/<scenario_id>")
def get_scenario(scenario_id: str):
    """Get a specific scenario by ID."""
    scenario = scenario_manager.get_scenario(scenario_id)
    if scenario:
        return jsonify(scenario)
    return jsonify({"error": SCENARIO_NOT_FOUND}), HTTP_NOT_FOUND


@app.route(API_AGENTS_CREATE_ENDPOINT, methods=["POST"])
def create_agent():
    """Create a new agent for a scenario.

    This endpoint accepts only scenario IDs returned by /api/scenarios.
    """
    data = cast(Dict[str, Any], request.json)
    scenario_id = data.get("scenario_id")
    custom_scenario = data.get("custom_scenario")
    avatar_config = data.get("avatar")

    if custom_scenario is not None:
        return jsonify({"error": CUSTOM_SCENARIO_NOT_SUPPORTED}), HTTP_BAD_REQUEST

    if not scenario_id:
        return jsonify({"error": SCENARIO_ID_REQUIRED}), HTTP_BAD_REQUEST

    scenario = scenario_manager.get_scenario(scenario_id)
    if not scenario:
        logger.error("Scenario not found: %s", scenario_id)
        return jsonify({"error": SCENARIO_NOT_FOUND}), HTTP_NOT_FOUND

    try:
        agent_id = agent_manager.create_agent(scenario_id, scenario, avatar_config)
        return jsonify({"agent_id": agent_id, "scenario_id": scenario_id})
    except Exception as e:
        logger.error("Failed to create agent: %s", e)
        return jsonify({"error": str(e)}), HTTP_INTERNAL_SERVER_ERROR


@app.route("/api/agents/<agent_id>", methods=["DELETE"])
def delete_agent(agent_id: str):
    """Delete an agent."""
    try:
        agent_manager.delete_agent(agent_id)
        return jsonify({"success": True})
    except Exception as e:
        logger.error("Failed to delete agent: %s", e)
        return jsonify({"error": str(e)}), HTTP_INTERNAL_SERVER_ERROR


@app.route(API_CONVERSATIONS_ENDPOINT, methods=["POST"])
def create_conversation_record():
    """Create an in-progress conversation record when a session starts."""
    data = cast(Dict[str, Any], request.json)
    scenario_id = cast(str, data.get("scenario_id"))
    messages = data.get("messages", [])

    if not scenario_id:
        return jsonify({"error": SCENARIO_ID_REQUIRED}), HTTP_BAD_REQUEST

    user = get_current_user()

    if user is not None:
        metadata = {"user_name": user.name, "user_email": user.email}
        conversation_id = conversation_store.create_conversation(
            user_id=user.user_id,
            scenario_id=scenario_id,
            messages=messages,
            metadata=metadata,
        )
    else:
        conversation_id = conversation_manager.create_conversation_record(
            scenario_id=scenario_id,
            conversation_messages=messages,
        )

    if conversation_id:
        return jsonify({"conversation_id": conversation_id})
    return jsonify({"error": "Failed to create conversation"}), HTTP_INTERNAL_SERVER_ERROR


@app.route(f"{API_CONVERSATIONS_ENDPOINT}/<conversation_id>/messages", methods=["PATCH"])
def update_conversation_messages_endpoint(conversation_id: str):
    """Update messages on an in-progress conversation."""
    data = cast(Dict[str, Any], request.json)
    messages = data.get("messages", [])
    transcript = cast(str, data.get("transcript", ""))

    user = get_current_user()

    if user is not None:
        success = conversation_store.update_conversation_messages(
            user_id=user.user_id,
            conversation_id=conversation_id,
            messages=messages,
            transcript=transcript,
        )
    else:
        success = conversation_manager.update_conversation_messages(
            conversation_id=conversation_id,
            conversation_messages=messages,
            transcript_text=transcript,
        )

    if success:
        return jsonify({"success": True})
    return jsonify({"error": "Failed to update conversation"}), HTTP_INTERNAL_SERVER_ERROR


@app.route(API_ANALYZE_ENDPOINT, methods=["POST"])
def analyze_conversation():
    """Analyze a conversation for performance assessment and save it."""
    data = cast(Dict[str, Any], request.json)
    scenario_id = cast(str, data.get("scenario_id"))
    transcript = cast(str, data.get("transcript"))
    audio_data = data.get("audio_data", [])
    reference_text = cast(str, data.get("reference_text"))
    conversation_messages = cast(List[Dict[str, Any]], data.get("conversation_messages", []))
    existing_conversation_id = data.get("conversation_id")

    _log_analyze_request(scenario_id, transcript, reference_text)

    if not scenario_id or not transcript:
        return jsonify({"error": TRANSCRIPT_REQUIRED}), HTTP_BAD_REQUEST

    # Get current user (may be None if not authenticated)
    user = get_current_user()

    return _perform_conversation_analysis(
        scenario_id,
        transcript,
        audio_data,
        reference_text,
        conversation_messages,
        user,
        existing_conversation_id=existing_conversation_id,
    )


def _log_analyze_request(scenario_id: str, transcript: str, reference_text: str):
    """Log information about the analyze request."""
    logger.info(
        "Analyze request - scenario: %s, transcript length: %s, reference_text length: %s",
        scenario_id,
        len(transcript or ""),
        len(reference_text or ""),
    )


def _perform_conversation_analysis(
    scenario_id: str,
    transcript: str,
    audio_data: List[Dict[str, Any]],
    reference_text: str,
    conversation_messages: List[Dict[str, Any]],
    user: Optional[UserIdentity] = None,
    existing_conversation_id: Optional[str] = None,
):
    """Perform the actual conversation analysis and save to database if user is authenticated."""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    rubric = conversation_manager.get_rubric_for_scenario(scenario_id)

    try:
        tasks = [
            conversation_analyzer.analyze_conversation(scenario_id, transcript, rubric=rubric),
            pronunciation_assessor.assess_pronunciation(audio_data, reference_text),
        ]

        results = loop.run_until_complete(asyncio.gather(*tasks, return_exceptions=True))

        ai_assessment, pronunciation = results

        if isinstance(ai_assessment, Exception):
            logger.error("AI assessment failed: %s", ai_assessment)
            ai_assessment = None

        if isinstance(pronunciation, Exception):
            logger.error("Pronunciation assessment failed: %s", pronunciation)
            pronunciation = None

        response_data: Dict[str, Any] = {
            "ai_assessment": ai_assessment,
            "pronunciation_assessment": pronunciation,
        }

        assessment_data = {
            "ai_assessment": ai_assessment,
            "pronunciation_assessment": pronunciation,
        }

        # If an existing conversation was created during the session, update it
        if existing_conversation_id:
            if user is not None:
                updated = conversation_store.update_conversation_assessment(
                    user_id=user.user_id,
                    conversation_id=existing_conversation_id,
                    transcript=transcript,
                    assessment=assessment_data,
                    messages=conversation_messages,
                )
            else:
                updated = conversation_manager.update_conversation_with_assessment(
                    conversation_id=existing_conversation_id,
                    transcript_text=transcript,
                    conversation_messages=conversation_messages,
                    evaluation=ai_assessment if isinstance(ai_assessment, dict) else None,
                    pronunciation=pronunciation if isinstance(pronunciation, dict) else None,
                )
            if updated:
                response_data["conversation_id"] = existing_conversation_id
                logger.info("Updated existing conversation %s with assessment", existing_conversation_id)
            else:
                logger.warning("Failed to update conversation %s, falling back to create", existing_conversation_id)
                existing_conversation_id = None  # Fall through to create below

        # Create a new conversation record if none existed
        if not existing_conversation_id:
            if user is not None:
                metadata = {
                    "user_name": user.name,
                    "user_email": user.email,
                }
                conversation_id = conversation_store.save_conversation(
                    user_id=user.user_id,
                    scenario_id=scenario_id,
                    transcript=transcript,
                    assessment=assessment_data,
                    metadata=metadata,
                )
                if conversation_id:
                    response_data["conversation_id"] = conversation_id
                    logger.info("Conversation saved with ID: %s for user: %s", conversation_id, user.user_id)
                else:
                    logger.warning("Failed to save conversation for user: %s", user.user_id)
            else:
                conversation_id = conversation_manager.save_conversation(
                    scenario_id=scenario_id,
                    transcript=transcript,
                    conversation_messages=conversation_messages,
                    evaluation=ai_assessment if isinstance(ai_assessment, dict) else None,
                    pronunciation=pronunciation if isinstance(pronunciation, dict) else None,
                )
                if conversation_id:
                    response_data["conversation_id"] = conversation_id

        return jsonify(response_data)

    finally:
        loop.close()


@app.route(API_CONVERSATIONS_ENDPOINT, methods=["GET"])
@require_auth
def list_conversations():
    """List conversations for the authenticated user."""
    user = get_current_user()
    if user is None:
        return jsonify({"error": "Authentication required"}), HTTP_UNAUTHORIZED

    limit = request.args.get("limit", 20, type=int)
    offset = request.args.get("offset", 0, type=int)
    sort_by = request.args.get("sort_by", "created_at", type=str)
    sort_order = request.args.get("sort_order", "desc", type=str)

    # Validate pagination parameters
    limit = max(1, min(100, limit))
    offset = max(0, offset)

    result = conversation_store.list_user_conversations(
        user_id=user.user_id,
        limit=limit,
        offset=offset,
        sort_by=sort_by,
        sort_order=sort_order,
    )

    conversations = result.get("items", [])
    total = result.get("total", 0)

    # Enrich conversations with scenario names
    all_scenarios = scenario_manager.list_scenarios()
    scenario_map = {s["id"]: s["name"] for s in all_scenarios}
    for conv in conversations:
        conv["scenario_name"] = scenario_map.get(conv.get("scenario_id", ""), "Unknown Scenario")

    return jsonify({
        "conversations": conversations,
        "total": total,
        "limit": limit,
        "offset": offset,
    })


@app.route(f"{API_CONVERSATIONS_ENDPOINT}/<conversation_id>", methods=["GET"])
@require_auth
def get_conversation(conversation_id: str):
    """Get a specific conversation by ID.

    Users can only access their own conversations unless they have admin role.
    """
    user = get_current_user()
    if user is None:
        return jsonify({"error": "Authentication required"}), HTTP_UNAUTHORIZED

    # First, try to get conversation using user's ID as partition key (efficient)
    conversation = conversation_store.get_conversation(
        user_id=user.user_id,
        conversation_id=conversation_id,
    )

    # If not found and user is admin, try cross-partition query
    if conversation is None and user.is_admin:
        conversation = conversation_store.get_conversation_by_id_admin(conversation_id)

    if conversation is None:
        return jsonify({"error": CONVERSATION_NOT_FOUND}), HTTP_NOT_FOUND

    # Check access: user must own the conversation or be an admin
    if not user.can_access_user_data(conversation.get("user_id", "")):
        return jsonify({"error": ACCESS_DENIED}), HTTP_FORBIDDEN

    return jsonify(conversation)


@app.route(f"{API_CONVERSATIONS_ENDPOINT}/<conversation_id>", methods=["DELETE"])
@require_auth
def delete_conversation(conversation_id: str):
    """Delete a specific conversation.

    Users can only delete their own conversations unless they have admin role.
    """
    user = get_current_user()
    if user is None:
        return jsonify({"error": "Authentication required"}), HTTP_UNAUTHORIZED

    # First check if conversation exists and user has access
    conversation = conversation_store.get_conversation(
        user_id=user.user_id,
        conversation_id=conversation_id,
    )

    # If not found with user's partition key and user is admin, try admin lookup
    target_user_id = user.user_id
    if conversation is None and user.is_admin:
        conversation = conversation_store.get_conversation_by_id_admin(conversation_id)
        if conversation:
            target_user_id = conversation.get("user_id", "")

    if conversation is None:
        return jsonify({"error": CONVERSATION_NOT_FOUND}), HTTP_NOT_FOUND

    # Check access: user must own the conversation or be an admin
    if not user.can_access_user_data(conversation.get("user_id", "")):
        return jsonify({"error": ACCESS_DENIED}), HTTP_FORBIDDEN

    # Delete the conversation
    success = conversation_store.delete_conversation(
        user_id=target_user_id,
        conversation_id=conversation_id,
    )

    if success:
        return jsonify({"success": True})
    return jsonify({"error": "Failed to delete conversation"}), HTTP_INTERNAL_SERVER_ERROR


@app.route("/api/me", methods=["GET"])
def get_current_user_info():
    """Get information about the current authenticated user."""
    user = get_current_user()
    if user is None:
        return jsonify({"authenticated": False})

    return jsonify(
        {
            "authenticated": True,
            "user_id": user.user_id,
            "name": user.name,
            "email": user.email,
            "is_admin": user.is_admin,
        }
    )


@app.route(f"/{AUDIO_PROCESSOR_FILE}")
def audio_processor():
    """Serve the audio processor JavaScript file."""
    return send_from_directory("static", AUDIO_PROCESSOR_FILE)


@sock.route(WEBSOCKET_ENDPOINT)  # pyright: ignore[reportUnknownMemberType]
def voice_proxy(ws: simple_websocket.ws.Server):
    """WebSocket endpoint for voice proxy."""

    logger.info("New WebSocket connection")

    try:
        loop = asyncio.get_event_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

    loop.run_until_complete(voice_proxy_handler.handle_connection(ws))


@app.route(API_GRAPH_SCENARIO_ENDPOINT, methods=["POST"])
def generate_graph_scenario():
    """Generate a scenario based on Graph API data."""

    # Simulate API delay
    time.sleep(2)

    try:
        docker_canned_file = Path("/app/data/graph-api-canned.json")
        dev_canned_file = Path(__file__).parent.parent.parent / "data" / "graph-api-canned.json"

        canned_file = docker_canned_file if docker_canned_file.exists() else dev_canned_file

        if not canned_file.exists():
            logger.error("Canned Graph API file not found at %s", canned_file)
            graph_data: Dict[str, Any] = {"value": []}
        else:
            with open(canned_file, encoding="utf-8") as f:
                graph_data = json.load(f)

        scenario = scenario_manager.generate_scenario_from_graph(graph_data)

        return jsonify(scenario)
    except Exception as e:
        logger.error("Failed to generate Graph scenario: %s", e)
        return jsonify({"error": str(e)}), HTTP_INTERNAL_SERVER_ERROR


def main():
    """Run the Flask application."""
    host = config["host"]
    port = config["port"]
    print(f"Starting Live Voice Practice on http://{host}:{port}")

    debug_mode = os.getenv("FLASK_ENV") == "development"
    app.run(host=host, port=port, debug=debug_mode)


if __name__ == "__main__":
    main()
