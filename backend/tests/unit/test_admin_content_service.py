# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Unit tests for the admin content service (scenarios, rubrics, transcripts)."""

from typing import Any, Dict, List, Optional

import pytest

from src.services.admin_content_service import (
    AdminContentService,
    ContentConflictError,
    ContentValidationError,
)


class FakeCosmosRepository:
    """In-memory stand-in for CosmosRepository keyed by an id field."""

    def __init__(self, id_field: str) -> None:
        self.id_field = id_field
        self.items: Dict[str, Dict[str, Any]] = {}

    def list_all(self) -> List[Dict[str, Any]]:
        return list(self.items.values())

    def get(self, resource_id: str) -> Optional[Dict[str, Any]]:
        return self.items.get(resource_id)

    def exists(self, resource_id: str) -> bool:
        return resource_id in self.items

    def upsert(self, document: Dict[str, Any]) -> Dict[str, Any]:
        resource_id = str(document[self.id_field])
        stored = dict(document)
        stored["id"] = resource_id
        self.items[resource_id] = stored
        return stored

    def delete(self, resource_id: str) -> bool:
        return self.items.pop(resource_id, None) is not None


class FakeBlobRepository:
    """In-memory stand-in for BlobRepository."""

    def __init__(self) -> None:
        self.blobs: Dict[str, str] = {}

    def list_names(self, prefix: str = "") -> List[str]:
        return [name for name in self.blobs if name.startswith(prefix)]

    def exists(self, blob_name: str) -> bool:
        return blob_name in self.blobs

    def get_text(self, blob_name: str) -> Optional[str]:
        return self.blobs.get(blob_name)

    def upload_text(self, blob_name: str, text: str) -> None:
        self.blobs[blob_name] = text

    def delete(self, blob_name: str) -> bool:
        return self.blobs.pop(blob_name, None) is not None


@pytest.fixture
def service() -> AdminContentService:
    svc = AdminContentService()
    svc._scenarios = FakeCosmosRepository("scenarioId")  # type: ignore[assignment]
    svc._rubrics = FakeCosmosRepository("rubricId")  # type: ignore[assignment]
    svc._transcripts = FakeBlobRepository()  # type: ignore[assignment]
    return svc


def _scenario(scenario_id: str = "s1") -> Dict[str, Any]:
    return {"scenarioId": scenario_id, "title": "Test scenario"}


def _rubric(rubric_id: str = "r1", scenario_ids: Optional[List[str]] = None) -> Dict[str, Any]:
    return {
        "rubricId": rubric_id,
        "appliesTo": {"scenarioIds": scenario_ids or []},
        "criteria": [{"criterionId": "c1", "name": "Crit", "levels": [{"level": 1}]}],
    }


class TestScenarioCrud:
    def test_create_and_get_scenario_stamps_audit(self, service: AdminContentService) -> None:
        changed: List[Dict[str, Any]] = []
        service.configure(on_scenario_change=changed.append)

        saved = service.create_scenario(_scenario(), updated_by="trainer@example.com")

        assert saved["scenarioId"] == "s1"
        assert saved["metadata"]["lastUpdatedBy"] == "trainer@example.com"
        assert "lastUpdatedAt" in saved["metadata"]
        assert changed and changed[0]["scenarioId"] == "s1"
        assert service.get_scenario("s1") is not None

    def test_create_duplicate_scenario_conflicts(self, service: AdminContentService) -> None:
        service.create_scenario(_scenario(), updated_by="t")
        with pytest.raises(ContentConflictError):
            service.create_scenario(_scenario(), updated_by="t")

    def test_create_invalid_scenario_raises_validation(self, service: AdminContentService) -> None:
        with pytest.raises(ContentValidationError) as exc:
            service.create_scenario({"title": "no id"}, updated_by="t")
        assert exc.value.details

    def test_update_missing_scenario_raises_keyerror(self, service: AdminContentService) -> None:
        with pytest.raises(KeyError):
            service.update_scenario("ghost", _scenario("ghost"), updated_by="t")

    def test_delete_scenario_refused_when_referenced(self, service: AdminContentService) -> None:
        service.create_scenario(_scenario("s1"), updated_by="t")
        service._rubrics.upsert(_rubric("r1", ["s1"]))  # type: ignore[attr-defined]
        with pytest.raises(ContentConflictError) as exc:
            service.delete_scenario("s1")
        assert "r1" in exc.value.details

    def test_delete_scenario_removes_from_cache(self, service: AdminContentService) -> None:
        removed: List[str] = []
        service.configure(on_scenario_delete=removed.append)
        service.create_scenario(_scenario("s1"), updated_by="t")
        assert service.delete_scenario("s1") is True
        assert removed == ["s1"]


class TestRubricCrud:
    def test_create_rubric_validates_scenario_links(self, service: AdminContentService) -> None:
        with pytest.raises(ContentValidationError) as exc:
            service.create_rubric(_rubric("r1", ["missing"]), updated_by="t")
        assert any("missing" in detail for detail in exc.value.details)

    def test_create_rubric_with_valid_link(self, service: AdminContentService) -> None:
        service.create_scenario(_scenario("s1"), updated_by="t")
        reloaded: List[Dict[str, Any]] = []
        service.configure(on_rubric_change=reloaded.append)
        saved = service.create_rubric(_rubric("r1", ["s1"]), updated_by="t")
        assert saved["rubricId"] == "r1"
        assert reloaded

    def test_create_invalid_rubric_no_criteria(self, service: AdminContentService) -> None:
        with pytest.raises(ContentValidationError):
            service.create_rubric({"rubricId": "r1", "criteria": []}, updated_by="t")

    def test_delete_rubric_triggers_callback(self, service: AdminContentService) -> None:
        deleted: List[Dict[str, Any]] = []
        service.configure(on_rubric_delete=deleted.append)
        service.create_scenario(_scenario("s1"), updated_by="t")
        service.create_rubric(_rubric("r1", ["s1"]), updated_by="t")
        assert service.delete_rubric("r1") is True
        assert deleted and deleted[0]["rubricId"] == "r1"


class TestTranscriptCrud:
    def test_save_list_and_get_transcript(self, service: AdminContentService) -> None:
        service.save_transcript("transcript-001", "Customer: hi")
        assert service.list_transcripts() == ["transcript-001"]
        assert service.get_transcript("transcript-001") == "Customer: hi"

    def test_save_transcript_requires_text(self, service: AdminContentService) -> None:
        with pytest.raises(ContentValidationError):
            service.save_transcript("t1", "")

    def test_delete_transcript_refused_when_referenced_by_scenario(self, service: AdminContentService) -> None:
        service.save_transcript("transcript-001", "text")
        service._scenarios.upsert(  # type: ignore[attr-defined]
            {"scenarioId": "s1", "title": "T", "exampleTranscripts": ["transcript-001"]}
        )
        with pytest.raises(ContentConflictError) as exc:
            service.delete_transcript("transcript-001")
        assert any("scenario:s1" in detail for detail in exc.value.details)

    def test_delete_unreferenced_transcript(self, service: AdminContentService) -> None:
        service.save_transcript("transcript-009", "text")
        assert service.delete_transcript("transcript-009") is True
        assert service.list_transcripts() == []
