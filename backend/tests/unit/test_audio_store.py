"""Tests for temporary session audio storage."""

import base64

from src.services import audio_store
from src.services.audio_store import SessionAudioStore


def test_session_audio_store_keeps_recent_audio_when_size_limit_is_exceeded(monkeypatch, tmp_path):
    """Stored pronunciation audio is capped so long recordings cannot time out analysis."""
    monkeypatch.setattr(audio_store, "DEFAULT_MAX_AUDIO_BYTES", 8)

    store = SessionAudioStore(base_dir=tmp_path)

    store.append_user_audio("agent-1", base64.b64encode(b"123456").decode("utf-8"))
    store.append_user_audio("agent-1", base64.b64encode(b"7890").decode("utf-8"))

    assert store.get_user_audio("agent-1") == b"34567890"
    assert store.get_metadata("agent-1")["bytes"] == 8
    assert store.get_metadata("agent-1")["chunks"] == 2
