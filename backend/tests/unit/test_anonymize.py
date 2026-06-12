# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Unit tests for trainee identity anonymization."""

from typing import Any, Dict

from src.services import anonymize


def _conversation() -> Dict[str, Any]:
    return {
        "id": "c1",
        "user_id": "user-abc",
        "metadata": {"user_name": "Jane Doe", "user_email": "jane@example.com"},
    }


def test_user_hash_is_deterministic_and_short(monkeypatch: Any) -> None:
    monkeypatch.setattr(anonymize.config, "get", lambda key, default=None: "salt-1" if "salt" in key else default)
    assert anonymize.user_hash("user-abc") == anonymize.user_hash("user-abc")
    assert len(anonymize.user_hash("user-abc")) == 6


def test_resolve_user_hash_round_trip(monkeypatch: Any) -> None:
    monkeypatch.setattr(anonymize.config, "get", lambda key, default=None: "salt-1" if "salt" in key else default)
    candidates = ["user-abc", "user-xyz"]
    hashed = anonymize.user_hash("user-xyz")
    assert anonymize.resolve_user_hash(hashed, candidates) == "user-xyz"
    assert anonymize.resolve_user_hash(anonymize.trainee_label("user-xyz"), candidates) == "user-xyz"
    assert anonymize.resolve_user_hash("nope", candidates) is None


def test_anonymize_record_when_identities_hidden(monkeypatch: Any) -> None:
    def fake_get(key: str, default: Any = None) -> Any:
        if key == "show_trainee_identities":
            return False
        if "salt" in key:
            return "salt-1"
        return default

    monkeypatch.setattr(anonymize.config, "get", fake_get)

    result = anonymize.anonymize_conversation_record(_conversation())

    assert result["user_id"] == anonymize.user_hash("user-abc")
    assert result["user_label"].startswith(anonymize.IDENTITY_PREFIX)
    assert "user_name" not in result["metadata"]
    assert "user_email" not in result["metadata"]


def test_anonymize_record_when_identities_visible(monkeypatch: Any) -> None:
    monkeypatch.setattr(
        anonymize.config,
        "get",
        lambda key, default=None: True if key == "show_trainee_identities" else default,
    )

    original = _conversation()
    result = anonymize.anonymize_conversation_record(original)

    assert result["user_id"] == "user-abc"
    assert result["metadata"]["user_name"] == "Jane Doe"
