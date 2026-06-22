# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Admin content service: CRUD orchestration for scenarios, rubrics, transcripts.

This is the single entry point used by the admin routes. It owns validation,
referential-integrity checks, audit stamping, and in-memory cache invalidation
so that writes take effect for new conversations without restarting the pod.

Low-level persistence is delegated to :class:`CosmosRepository` (scenarios,
rubrics) and :class:`BlobRepository` (transcripts). Cache invalidation is wired
in by ``configure()`` from ``src.app`` so this module stays import-cycle free.
"""

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from src.config import config
from src.services.blob_repository import BlobRepository, BlobRepositoryError
from src.services.content_validation import validate_rubric, validate_scenario
from src.services.cosmos_repository import CosmosRepository

logger = logging.getLogger(__name__)

TRANSCRIPT_BLOB_SUFFIX = ".txt"
SAMPLE_TRANSCRIPTS_DIR = Path("samples/transcripts")


class ContentValidationError(ValueError):
    """Raised when a document fails schema validation. Carries structured details."""

    def __init__(self, message: str, details: Optional[List[str]] = None):
        super().__init__(message)
        self.details = details or []


class ContentConflictError(RuntimeError):
    """Raised when an operation violates referential integrity (e.g. a held delete)."""

    def __init__(self, message: str, details: Optional[List[str]] = None):
        super().__init__(message)
        self.details = details or []


def _transcript_id_from_blob(blob_name: str) -> str:
    """Strip the ``.txt`` suffix to recover the transcript id from a blob name."""
    if blob_name.endswith(TRANSCRIPT_BLOB_SUFFIX):
        return blob_name[: -len(TRANSCRIPT_BLOB_SUFFIX)]
    return blob_name


class AdminContentService:
    """Coordinates CRUD across scenarios, rubrics, and transcripts."""

    def __init__(self) -> None:
        self._scenarios = CosmosRepository(config.get("cosmos_scenarios_container", "scenarios"), id_field="scenarioId")
        self._rubrics = CosmosRepository(config.get("cosmos_rubrics_container", "rubrics"), id_field="rubricId")
        self._transcripts = BlobRepository(config.get("transcripts_storage_container", "transcripts"))
        self._sample_transcript_dir = SAMPLE_TRANSCRIPTS_DIR
        # Cache-invalidation callbacks, injected by configure().
        self._on_scenario_change: Optional[Callable[[Dict[str, Any]], None]] = None
        self._on_scenario_delete: Optional[Callable[[str], None]] = None
        self._on_rubric_change: Optional[Callable[[Dict[str, Any]], None]] = None
        self._on_rubric_delete: Optional[Callable[[Dict[str, Any]], None]] = None

    def configure(
        self,
        *,
        on_scenario_change: Optional[Callable[[Dict[str, Any]], None]] = None,
        on_scenario_delete: Optional[Callable[[str], None]] = None,
        on_rubric_change: Optional[Callable[[Dict[str, Any]], None]] = None,
        on_rubric_delete: Optional[Callable[[Dict[str, Any]], None]] = None,
    ) -> None:
        """Wire in cache-invalidation callbacks from the application managers."""
        self._on_scenario_change = on_scenario_change
        self._on_scenario_delete = on_scenario_delete
        self._on_rubric_change = on_rubric_change
        self._on_rubric_delete = on_rubric_delete

    # ----------------------------------------------------------------- helpers

    @staticmethod
    def _stamp_audit(document: Dict[str, Any], updated_by: str) -> Dict[str, Any]:
        """Stamp ``metadata.lastUpdatedAt`` / ``lastUpdatedBy`` on a document copy."""
        stamped = dict(document)
        metadata = dict(stamped.get("metadata") or {})
        metadata["lastUpdatedAt"] = datetime.now(timezone.utc).isoformat()
        metadata["lastUpdatedBy"] = updated_by
        stamped["metadata"] = metadata
        return stamped

    # --------------------------------------------------------------- scenarios

    def list_scenarios(self) -> List[Dict[str, Any]]:
        """Return all raw scenario documents."""
        return self._scenarios.list_all()

    def get_scenario(self, scenario_id: str) -> Optional[Dict[str, Any]]:
        """Return a single raw scenario document or ``None``."""
        return self._scenarios.get(scenario_id)

    def create_scenario(self, document: Dict[str, Any], updated_by: str) -> Dict[str, Any]:
        """Create a scenario after validation; refuses if the id already exists."""
        errors = validate_scenario(document)
        if errors:
            raise ContentValidationError("Scenario validation failed", errors)
        scenario_id = str(document["scenarioId"])
        if self._scenarios.exists(scenario_id):
            raise ContentConflictError(f"Scenario '{scenario_id}' already exists")
        return self._save_scenario(document, updated_by)

    def update_scenario(self, scenario_id: str, document: Dict[str, Any], updated_by: str) -> Dict[str, Any]:
        """Update an existing scenario after validation."""
        document = dict(document)
        document["scenarioId"] = scenario_id
        errors = validate_scenario(document)
        if errors:
            raise ContentValidationError("Scenario validation failed", errors)
        if not self._scenarios.exists(scenario_id):
            raise KeyError(scenario_id)
        return self._save_scenario(document, updated_by)

    def _save_scenario(self, document: Dict[str, Any], updated_by: str) -> Dict[str, Any]:
        stamped = self._stamp_audit(document, updated_by)
        saved = self._scenarios.upsert(stamped)
        if self._on_scenario_change:
            self._on_scenario_change(saved)
        return saved

    def delete_scenario(self, scenario_id: str) -> bool:
        """Delete a scenario; refuses if any rubric references it."""
        holders = [
            str(rubric.get("rubricId"))
            for rubric in self._rubrics.list_all()
            if scenario_id in (rubric.get("appliesTo", {}) or {}).get("scenarioIds", [])
        ]
        if holders:
            raise ContentConflictError(
                f"Scenario '{scenario_id}' is referenced by rubric(s) and cannot be deleted",
                holders,
            )
        deleted = self._scenarios.delete(scenario_id)
        if deleted and self._on_scenario_delete:
            self._on_scenario_delete(scenario_id)
        return deleted

    # ----------------------------------------------------------------- rubrics

    def list_rubrics(self) -> List[Dict[str, Any]]:
        """Return all raw rubric documents."""
        return self._rubrics.list_all()

    def get_rubric(self, rubric_id: str) -> Optional[Dict[str, Any]]:
        """Return a single raw rubric document or ``None``."""
        return self._rubrics.get(rubric_id)

    def create_rubric(self, document: Dict[str, Any], updated_by: str) -> Dict[str, Any]:
        """Create a rubric after validation and scenario-link checks."""
        self._validate_rubric_with_links(document)
        rubric_id = str(document["rubricId"])
        if self._rubrics.exists(rubric_id):
            raise ContentConflictError(f"Rubric '{rubric_id}' already exists")
        return self._save_rubric(document, updated_by)

    def update_rubric(self, rubric_id: str, document: Dict[str, Any], updated_by: str) -> Dict[str, Any]:
        """Update an existing rubric after validation and scenario-link checks."""
        document = dict(document)
        document["rubricId"] = rubric_id
        self._validate_rubric_with_links(document)
        if not self._rubrics.exists(rubric_id):
            raise KeyError(rubric_id)
        return self._save_rubric(document, updated_by)

    def _validate_rubric_with_links(self, document: Dict[str, Any]) -> None:
        errors = validate_rubric(document)
        if errors:
            raise ContentValidationError("Rubric validation failed", errors)
        scenario_ids = (document.get("appliesTo", {}) or {}).get("scenarioIds", [])
        missing = [sid for sid in scenario_ids if not self._scenarios.exists(str(sid))]
        if missing:
            raise ContentValidationError(
                "Rubric references scenarioIds that do not exist",
                [f"Unknown scenarioId: {sid}" for sid in missing],
            )

    def _save_rubric(self, document: Dict[str, Any], updated_by: str) -> Dict[str, Any]:
        stamped = self._stamp_audit(document, updated_by)
        saved = self._rubrics.upsert(stamped)
        if self._on_rubric_change:
            self._on_rubric_change(saved)
        return saved

    def delete_rubric(self, rubric_id: str) -> bool:
        """Delete a rubric and invalidate its scenario cache bindings."""
        existing = self._rubrics.get(rubric_id)
        deleted = self._rubrics.delete(rubric_id)
        if deleted and existing and self._on_rubric_delete:
            self._on_rubric_delete(existing)
        return deleted

    # ------------------------------------------------------------- transcripts

    def list_transcripts(self) -> List[str]:
        """Return transcript ids from Blob Storage plus baked-in sample files."""
        ids = set(self._sample_transcript_ids())
        try:
            names = self._transcripts.list_names()
            ids.update(_transcript_id_from_blob(name) for name in names if name.endswith(TRANSCRIPT_BLOB_SUFFIX))
        except BlobRepositoryError as error:
            logger.warning("Blob transcript list unavailable; using baked-in samples only: %s", error)
        return sorted(ids)

    def get_transcript(self, transcript_id: str) -> Optional[str]:
        """Return the text of a transcript, or ``None`` if it does not exist."""
        try:
            text = self._transcripts.get_text(f"{transcript_id}{TRANSCRIPT_BLOB_SUFFIX}")
            if text is not None:
                return text
        except BlobRepositoryError as error:
            logger.warning("Blob transcript read unavailable; checking baked-in samples: %s", error)
        return self._get_sample_transcript(transcript_id)

    def save_transcript(self, transcript_id: str, text: str) -> None:
        """Create or replace a transcript's text."""
        if not transcript_id or not transcript_id.strip():
            raise ContentValidationError("Transcript id is required")
        if not isinstance(text, str) or not text.strip():
            raise ContentValidationError("Transcript text is required")
        self._transcripts.upload_text(f"{transcript_id}{TRANSCRIPT_BLOB_SUFFIX}", text)

    def transcript_exists(self, transcript_id: str) -> bool:
        """Return whether a transcript exists in Blob Storage or built-in samples."""
        return self._blob_transcript_exists(transcript_id) or self._sample_transcript_path(transcript_id).is_file()

    def delete_transcript(self, transcript_id: str) -> bool:
        """Delete a transcript; refuses if a scenario or rubric references it."""
        holders = self._transcript_holders(transcript_id)
        if holders:
            raise ContentConflictError(
                f"Transcript '{transcript_id}' is referenced and cannot be deleted",
                holders,
            )
        if self._sample_transcript_path(transcript_id).is_file() and not self._blob_transcript_exists(transcript_id):
            raise ContentConflictError(f"Transcript '{transcript_id}' is a built-in sample and cannot be deleted")
        return self._transcripts.delete(f"{transcript_id}{TRANSCRIPT_BLOB_SUFFIX}")

    def _blob_transcript_exists(self, transcript_id: str) -> bool:
        try:
            return self._transcripts.exists(f"{transcript_id}{TRANSCRIPT_BLOB_SUFFIX}")
        except BlobRepositoryError as error:
            logger.warning("Blob transcript exists check unavailable: %s", error)
            return False

    def _sample_transcript_path(self, transcript_id: str) -> Path:
        return self._sample_transcript_dir / f"{transcript_id}{TRANSCRIPT_BLOB_SUFFIX}"

    def _sample_transcript_ids(self) -> List[str]:
        if not self._sample_transcript_dir.is_dir():
            return []
        return sorted(
            path.stem for path in self._sample_transcript_dir.glob(f"*{TRANSCRIPT_BLOB_SUFFIX}") if path.is_file()
        )

    def _get_sample_transcript(self, transcript_id: str) -> Optional[str]:
        path = self._sample_transcript_path(transcript_id)
        if not path.is_file():
            return None
        return path.read_text(encoding="utf-8")

    def _transcript_holders(self, transcript_id: str) -> List[str]:
        """List scenarios/rubrics that reference a transcript id."""
        holders: List[str] = []
        for scenario in self._scenarios.list_all():
            if transcript_id in scenario.get("exampleTranscripts", []):
                holders.append(f"scenario:{scenario.get('scenarioId')}")
        for rubric in self._rubrics.list_all():
            if transcript_id in rubric.get("referenceTranscripts", []):
                holders.append(f"rubric:{rubric.get('rubricId')}")
        return holders


# Singleton instance used by the admin routes.
admin_content_service = AdminContentService()
