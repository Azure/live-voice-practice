# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Tests for the authentication decorators and identity helpers."""

import json
from unittest.mock import patch

import pytest
from flask import Flask, jsonify
from flask.testing import FlaskClient

from src.services.auth import require_trainer


@pytest.fixture
def client() -> FlaskClient:
    """A minimal Flask app exposing a trainer-gated route."""
    flask_app = Flask(__name__)
    flask_app.config["TESTING"] = True

    @flask_app.route("/protected")
    @require_trainer
    def _protected():  # pyright: ignore[reportUnusedFunction]
        return jsonify({"ok": True})

    return flask_app.test_client()


_AUTH_HEADERS = {
    "x-ms-client-principal-id": "user-1",
    "x-ms-client-principal-name": "Test User",
}


class TestRequireTrainer:
    """Test cases for the @require_trainer decorator."""

    @patch("src.services.role_store.role_store")
    def test_trainer_allowed(self, mock_role_store, client: FlaskClient):
        """A user with the trainer role passes through."""
        mock_role_store.get_user_role.return_value = "trainer"

        response = client.get("/protected", headers=_AUTH_HEADERS)

        assert response.status_code == 200
        assert json.loads(response.data) == {"ok": True}
        mock_role_store.get_user_role.assert_called_once_with("user-1")

    @patch("src.services.role_store.role_store")
    def test_trainee_forbidden(self, mock_role_store, client: FlaskClient):
        """An authenticated non-trainer gets 403."""
        mock_role_store.get_user_role.return_value = "trainee"

        response = client.get("/protected", headers=_AUTH_HEADERS)

        assert response.status_code == 403
        assert json.loads(response.data)["error"] == "Access denied"

    @patch("src.services.role_store.role_store")
    def test_unauthenticated_unauthorized(self, mock_role_store, client: FlaskClient):
        """A request without auth headers gets 401 and never resolves a role."""
        response = client.get("/protected")

        assert response.status_code == 401
        assert json.loads(response.data)["error"] == "Authentication required"
        mock_role_store.get_user_role.assert_not_called()
