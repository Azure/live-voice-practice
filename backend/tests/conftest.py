"""Local test defaults; no real Entra or Azure endpoints are contacted."""

import os
import time

import jwt
import pytest

os.environ.setdefault("AUTH_TENANT_ID", "11111111-1111-1111-1111-111111111111")
os.environ.setdefault("AUTH_AUDIENCE", "22222222-2222-2222-2222-222222222222")
os.environ.setdefault("AUTH_PUBLIC_ORIGIN", "https://voice.example")


@pytest.fixture(autouse=True)
def local_route_credentials(request, monkeypatch):
    """Keep existing route unit tests focused on routing, not token cryptography."""
    if request.module.__name__.rsplit(".", 1)[-1] not in {
        "test_app",
        "test_auth",
        "test_admin_content_routes",
    }:
        return
    from src.services import auth

    def validate(token):
        if token != "local-test":
            raise jwt.InvalidTokenError("Invalid fixture token")
        return {
            "tid": os.environ["AUTH_TENANT_ID"],
            "oid": "33333333-3333-3333-3333-333333333333",
            "exp": time.time() + 600,
        }

    monkeypatch.setattr(auth, "validate_access_token", validate)
