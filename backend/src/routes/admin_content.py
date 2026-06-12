# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Admin content-management REST API (scenarios, rubrics, transcripts, materials).

All routes are gated by :func:`require_trainer`. Handlers stay thin: they parse
the request, delegate to the service layer, and translate domain exceptions
into structured JSON errors. The blueprint is registered in ``src.app``.
"""

import logging
from typing import Any, Callable, Dict, Tuple

from flask import Blueprint, jsonify, request

from src.services.admin_content_service import (
    ContentConflictError,
    ContentValidationError,
    admin_content_service,
)
from src.services.auth import get_current_user, require_trainer
from src.services.blob_repository import BlobRepositoryError
from src.services.cosmos_repository import CosmosRepositoryError
from src.services.materials_service import materials_service

logger = logging.getLogger(__name__)

admin_content_bp = Blueprint("admin_content", __name__, url_prefix="/api/admin")

HTTP_BAD_REQUEST = 400
HTTP_NOT_FOUND = 404
HTTP_CONFLICT = 409
HTTP_SERVICE_UNAVAILABLE = 503


def _updated_by() -> str:
    """Resolve the identifier to stamp on audit fields from the current user."""
    user = get_current_user()
    if user is None:
        return "unknown"
    return user.email or user.user_id or "unknown"


def _json_body() -> Dict[str, Any]:
    """Return the request JSON body as a dict (empty dict if absent)."""
    body = request.get_json(silent=True)
    return body if isinstance(body, dict) else {}


def _handle(operation: Callable[[], Any]) -> Tuple[Any, int]:
    """Run a service operation and translate domain errors into JSON responses."""
    try:
        result = operation()
        return jsonify(result), 200
    except ContentValidationError as exc:
        return jsonify({"error": str(exc), "details": exc.details}), HTTP_BAD_REQUEST
    except ContentConflictError as exc:
        return jsonify({"error": str(exc), "details": exc.details}), HTTP_CONFLICT
    except KeyError as exc:
        return jsonify({"error": f"Not found: {exc}"}), HTTP_NOT_FOUND
    except (CosmosRepositoryError, BlobRepositoryError) as exc:
        logger.error("Admin content storage error: %s", exc)
        return jsonify({"error": "Content storage is not available"}), HTTP_SERVICE_UNAVAILABLE


# --------------------------------------------------------------------- scenarios


@admin_content_bp.route("/scenarios", methods=["GET"])
@require_trainer
def list_scenarios() -> Tuple[Any, int]:
    """List all raw scenario documents."""
    return _handle(lambda: {"items": admin_content_service.list_scenarios()})


@admin_content_bp.route("/scenarios", methods=["POST"])
@require_trainer
def create_scenario() -> Tuple[Any, int]:
    """Create a scenario."""
    return _handle(lambda: admin_content_service.create_scenario(_json_body(), _updated_by()))


@admin_content_bp.route("/scenarios/<scenario_id>", methods=["GET"])
@require_trainer
def get_scenario(scenario_id: str) -> Tuple[Any, int]:
    """Read a single scenario document."""
    document = admin_content_service.get_scenario(scenario_id)
    if document is None:
        return jsonify({"error": "Scenario not found"}), HTTP_NOT_FOUND
    return jsonify(document), 200


@admin_content_bp.route("/scenarios/<scenario_id>", methods=["PUT"])
@require_trainer
def update_scenario(scenario_id: str) -> Tuple[Any, int]:
    """Update a scenario."""
    return _handle(lambda: admin_content_service.update_scenario(scenario_id, _json_body(), _updated_by()))


@admin_content_bp.route("/scenarios/<scenario_id>", methods=["DELETE"])
@require_trainer
def delete_scenario(scenario_id: str) -> Tuple[Any, int]:
    """Delete a scenario (refused if referenced by a rubric)."""
    return _handle(lambda: {"deleted": admin_content_service.delete_scenario(scenario_id)})


# ----------------------------------------------------------------------- rubrics


@admin_content_bp.route("/rubrics", methods=["GET"])
@require_trainer
def list_rubrics() -> Tuple[Any, int]:
    """List all raw rubric documents."""
    return _handle(lambda: {"items": admin_content_service.list_rubrics()})


@admin_content_bp.route("/rubrics", methods=["POST"])
@require_trainer
def create_rubric() -> Tuple[Any, int]:
    """Create a rubric."""
    return _handle(lambda: admin_content_service.create_rubric(_json_body(), _updated_by()))


@admin_content_bp.route("/rubrics/<rubric_id>", methods=["GET"])
@require_trainer
def get_rubric(rubric_id: str) -> Tuple[Any, int]:
    """Read a single rubric document."""
    document = admin_content_service.get_rubric(rubric_id)
    if document is None:
        return jsonify({"error": "Rubric not found"}), HTTP_NOT_FOUND
    return jsonify(document), 200


@admin_content_bp.route("/rubrics/<rubric_id>", methods=["PUT"])
@require_trainer
def update_rubric(rubric_id: str) -> Tuple[Any, int]:
    """Update a rubric."""
    return _handle(lambda: admin_content_service.update_rubric(rubric_id, _json_body(), _updated_by()))


@admin_content_bp.route("/rubrics/<rubric_id>", methods=["DELETE"])
@require_trainer
def delete_rubric(rubric_id: str) -> Tuple[Any, int]:
    """Delete a rubric."""
    return _handle(lambda: {"deleted": admin_content_service.delete_rubric(rubric_id)})


# ------------------------------------------------------------------- transcripts


@admin_content_bp.route("/transcripts", methods=["GET"])
@require_trainer
def list_transcripts() -> Tuple[Any, int]:
    """List available transcript ids."""
    return _handle(lambda: {"items": admin_content_service.list_transcripts()})


@admin_content_bp.route("/transcripts", methods=["POST"])
@require_trainer
def create_transcript() -> Tuple[Any, int]:
    """Create/upload a transcript (JSON ``{transcriptId, text}`` or multipart file)."""
    transcript_id, text = _parse_transcript_request()
    if not transcript_id:
        return jsonify({"error": "transcriptId is required"}), HTTP_BAD_REQUEST
    if admin_content_service.transcript_exists(transcript_id):
        return jsonify({"error": f"Transcript '{transcript_id}' already exists"}), HTTP_CONFLICT
    return _handle(lambda: _save_transcript(transcript_id, text))


@admin_content_bp.route("/transcripts/<transcript_id>", methods=["GET"])
@require_trainer
def get_transcript(transcript_id: str) -> Tuple[Any, int]:
    """Fetch transcript text."""
    text = admin_content_service.get_transcript(transcript_id)
    if text is None:
        return jsonify({"error": "Transcript not found"}), HTTP_NOT_FOUND
    return jsonify({"transcriptId": transcript_id, "text": text}), 200


@admin_content_bp.route("/transcripts/<transcript_id>", methods=["PUT"])
@require_trainer
def update_transcript(transcript_id: str) -> Tuple[Any, int]:
    """Replace transcript text."""
    text = _json_body().get("text", "")
    return _handle(lambda: _save_transcript(transcript_id, text))


@admin_content_bp.route("/transcripts/<transcript_id>", methods=["DELETE"])
@require_trainer
def delete_transcript(transcript_id: str) -> Tuple[Any, int]:
    """Delete a transcript (refused if referenced by a scenario or rubric)."""
    return _handle(lambda: {"deleted": admin_content_service.delete_transcript(transcript_id)})


def _parse_transcript_request() -> Tuple[str, str]:
    """Extract (transcriptId, text) from either a multipart upload or JSON body."""
    if "file" in request.files:
        uploaded = request.files["file"]
        transcript_id = request.form.get("transcriptId") or (uploaded.filename or "").rsplit(".", 1)[0]
        return transcript_id, uploaded.read().decode("utf-8")
    body = _json_body()
    return str(body.get("transcriptId", "")), str(body.get("text", ""))


def _save_transcript(transcript_id: str, text: str) -> Dict[str, Any]:
    admin_content_service.save_transcript(transcript_id, text)
    return {"transcriptId": transcript_id}


# --------------------------------------------------------------- support materials


@admin_content_bp.route("/materials", methods=["GET"])
@require_trainer
def list_materials() -> Tuple[Any, int]:
    """List support-material documents."""
    if materials_service is None:
        return jsonify({"items": []}), 200
    return jsonify({"items": materials_service.list_materials()}), 200


@admin_content_bp.route("/materials", methods=["POST"])
@require_trainer
def upload_material() -> Tuple[Any, int]:
    """Upload a PDF support material and best-effort trigger a reindex."""
    if materials_service is None:
        return jsonify({"error": "Support materials are not available"}), HTTP_SERVICE_UNAVAILABLE
    if "file" not in request.files:
        return jsonify({"error": "A multipart 'file' field is required"}), HTTP_BAD_REQUEST
    uploaded = request.files["file"]
    filename = uploaded.filename or ""
    if not filename:
        return jsonify({"error": "Uploaded file must have a name"}), HTTP_BAD_REQUEST
    try:
        result = materials_service.upload_material(filename, uploaded.read())
        return jsonify(result), 200
    except ValueError as exc:
        return jsonify({"error": str(exc)}), HTTP_BAD_REQUEST
    except BlobRepositoryError as exc:
        logger.error("Material upload storage error: %s", exc)
        return jsonify({"error": "Content storage is not available"}), HTTP_SERVICE_UNAVAILABLE


@admin_content_bp.route("/materials/<path:name>", methods=["DELETE"])
@require_trainer
def delete_material(name: str) -> Tuple[Any, int]:
    """Delete a support-material blob and best-effort trigger a reindex."""
    if materials_service is None:
        return jsonify({"error": "Support materials are not available"}), HTTP_SERVICE_UNAVAILABLE
    try:
        return jsonify(materials_service.delete_material(name)), 200
    except BlobRepositoryError as exc:
        logger.error("Material delete storage error: %s", exc)
        return jsonify({"error": "Content storage is not available"}), HTTP_SERVICE_UNAVAILABLE
