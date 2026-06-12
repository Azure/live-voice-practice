"""Tests for the admin content-management endpoints (scenarios, rubrics, transcripts, materials)."""

import io
import json
from unittest.mock import patch

from flask.testing import FlaskClient

from src.app import app

TRAINER_HEADERS = {"x-ms-client-principal-id": "user-1", "x-ms-client-principal-name": "Trainer"}


class TestAdminContentRoutes:
    """RBAC and happy-path coverage for /api/admin content endpoints."""

    def setup_method(self):
        app.config["TESTING"] = True
        self.client: FlaskClient = app.test_client()  # pylint: disable=attribute-defined-outside-init

    # --------------------------------------------------------------- scenarios

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_list_scenarios_as_trainer(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.list_scenarios.return_value = [{"scenarioId": "s1", "title": "S1"}]

        response = self.client.get("/api/admin/scenarios", headers=TRAINER_HEADERS)

        assert response.status_code == 200
        assert json.loads(response.data)["items"][0]["scenarioId"] == "s1"

    @patch("src.services.role_store.role_store")
    def test_list_scenarios_forbidden_for_trainee(self, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainee"
        response = self.client.get("/api/admin/scenarios", headers=TRAINER_HEADERS)
        assert response.status_code == 403

    def test_list_scenarios_requires_auth(self):
        response = self.client.get("/api/admin/scenarios")
        assert response.status_code == 401

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_create_scenario_as_trainer(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.create_scenario.return_value = {"scenarioId": "s1", "title": "S1"}

        response = self.client.post(
            "/api/admin/scenarios",
            headers=TRAINER_HEADERS,
            json={"scenarioId": "s1", "title": "S1"},
        )

        assert response.status_code == 200
        mock_service.create_scenario.assert_called_once()

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_create_scenario_validation_error_returns_400(self, mock_service, mock_role_store):
        from src.services.admin_content_service import ContentValidationError

        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.create_scenario.side_effect = ContentValidationError("bad", ["'title' is required"])

        response = self.client.post("/api/admin/scenarios", headers=TRAINER_HEADERS, json={})

        assert response.status_code == 400
        assert json.loads(response.data)["details"] == ["'title' is required"]

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_delete_scenario_conflict_returns_409(self, mock_service, mock_role_store):
        from src.services.admin_content_service import ContentConflictError

        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.delete_scenario.side_effect = ContentConflictError("held", ["r1"])

        response = self.client.delete("/api/admin/scenarios/s1", headers=TRAINER_HEADERS)

        assert response.status_code == 409
        assert json.loads(response.data)["details"] == ["r1"]

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_get_scenario_not_found_returns_404(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.get_scenario.return_value = None
        response = self.client.get("/api/admin/scenarios/ghost", headers=TRAINER_HEADERS)
        assert response.status_code == 404

    # ----------------------------------------------------------------- rubrics

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_create_rubric_as_trainer(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.create_rubric.return_value = {"rubricId": "r1"}
        response = self.client.post("/api/admin/rubrics", headers=TRAINER_HEADERS, json={"rubricId": "r1"})
        assert response.status_code == 200

    @patch("src.services.role_store.role_store")
    def test_rubrics_forbidden_for_trainee(self, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainee"
        response = self.client.get("/api/admin/rubrics", headers=TRAINER_HEADERS)
        assert response.status_code == 403

    # ------------------------------------------------------------- transcripts

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_list_transcripts_as_trainer(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.list_transcripts.return_value = ["transcript-001"]
        response = self.client.get("/api/admin/transcripts", headers=TRAINER_HEADERS)
        assert response.status_code == 200
        assert json.loads(response.data)["items"] == ["transcript-001"]

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_create_transcript_json(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.transcript_exists.return_value = False
        response = self.client.post(
            "/api/admin/transcripts",
            headers=TRAINER_HEADERS,
            json={"transcriptId": "transcript-009", "text": "hello"},
        )
        assert response.status_code == 200
        mock_service.save_transcript.assert_called_once_with("transcript-009", "hello")

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_create_transcript_conflict(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.transcript_exists.return_value = True
        response = self.client.post(
            "/api/admin/transcripts",
            headers=TRAINER_HEADERS,
            json={"transcriptId": "transcript-001", "text": "hello"},
        )
        assert response.status_code == 409

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.admin_content_service")
    def test_get_transcript_not_found(self, mock_service, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_service.get_transcript.return_value = None
        response = self.client.get("/api/admin/transcripts/missing", headers=TRAINER_HEADERS)
        assert response.status_code == 404

    def test_transcripts_requires_auth(self):
        response = self.client.get("/api/admin/transcripts")
        assert response.status_code == 401

    # --------------------------------------------------------- support materials

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.materials_service")
    def test_list_materials_as_trainer(self, mock_materials, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_materials.list_materials.return_value = [{"name": "doc.pdf"}]
        response = self.client.get("/api/admin/materials", headers=TRAINER_HEADERS)
        assert response.status_code == 200
        assert json.loads(response.data)["items"][0]["name"] == "doc.pdf"

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.materials_service")
    def test_upload_material_as_trainer(self, mock_materials, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_materials.upload_material.return_value = {"name": "doc.pdf", "reindexTriggered": False}
        data = {"file": (io.BytesIO(b"%PDF-1.4 fake"), "doc.pdf")}
        response = self.client.post(
            "/api/admin/materials",
            headers=TRAINER_HEADERS,
            data=data,
            content_type="multipart/form-data",
        )
        assert response.status_code == 200
        mock_materials.upload_material.assert_called_once()

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.materials_service")
    def test_upload_material_without_file_returns_400(self, mock_materials, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        response = self.client.post(
            "/api/admin/materials",
            headers=TRAINER_HEADERS,
            data={},
            content_type="multipart/form-data",
        )
        assert response.status_code == 400

    @patch("src.services.role_store.role_store")
    def test_materials_forbidden_for_trainee(self, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainee"
        response = self.client.get("/api/admin/materials", headers=TRAINER_HEADERS)
        assert response.status_code == 403

    @patch("src.services.role_store.role_store")
    @patch("src.routes.admin_content.materials_service")
    def test_delete_material_as_trainer(self, mock_materials, mock_role_store):
        mock_role_store.get_user_role.return_value = "trainer"
        mock_materials.delete_material.return_value = {"name": "doc.pdf", "deleted": True, "reindexTriggered": False}
        response = self.client.delete("/api/admin/materials/doc.pdf", headers=TRAINER_HEADERS)
        assert response.status_code == 200
        assert json.loads(response.data)["deleted"] is True
