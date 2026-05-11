# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Temporary per-agent audio storage for pronunciation assessment."""

import base64
import logging
import re
import tempfile
import time
from pathlib import Path
from threading import Lock
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

SAFE_AGENT_ID = re.compile(r"[^A-Za-z0-9_.-]")
DEFAULT_MAX_AGE_SECONDS = 2 * 60 * 60


class SessionAudioStore:
    """Store user PCM audio received over WebSocket without sending it through analysis HTTP requests."""

    def __init__(self, base_dir: Optional[Path] = None):
        self.base_dir = base_dir or Path(tempfile.gettempdir()) / "live-voice-practice-audio"
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self._lock = Lock()
        self._metadata: Dict[str, Dict[str, int | float | str]] = {}
        self._messages: Dict[str, List[Dict[str, str]]] = {}

    def append_user_audio(self, agent_id: str, base64_audio: str) -> None:
        """Append one base64-encoded PCM chunk for an agent."""
        if not agent_id or not base64_audio:
            return

        audio_bytes = base64.b64decode(base64_audio)
        path = self._path_for_agent(agent_id)
        now = time.time()

        with self._lock:
            with path.open("ab") as audio_file:
                audio_file.write(audio_bytes)

            current = self._metadata.get(agent_id, {})
            self._metadata[agent_id] = {
                "path": str(path),
                "bytes": int(current.get("bytes", 0)) + len(audio_bytes),
                "chunks": int(current.get("chunks", 0)) + 1,
                "updated_at": now,
            }

        self.cleanup_old()

    def get_user_audio(self, agent_id: Optional[str]) -> Optional[bytes]:
        """Return accumulated PCM audio bytes for an agent, if present."""
        if not agent_id:
            return None

        path = self._path_for_agent(agent_id)
        if not path.exists():
            return None

        audio_bytes = path.read_bytes()
        return audio_bytes or None

    def get_metadata(self, agent_id: Optional[str]) -> Dict[str, int | float | str]:
        """Return stored audio metadata for diagnostics."""
        if not agent_id:
            return {}

        with self._lock:
            return dict(self._metadata.get(agent_id, {}))

    def append_message(self, agent_id: str, role: str, content: str) -> None:
        """Append a transcript message for an agent."""
        if not agent_id or not role or not content:
            return

        with self._lock:
            messages = self._messages.setdefault(agent_id, [])
            messages.append(
                {
                    "role": role,
                    "content": content,
                }
            )

    def get_messages(self, agent_id: Optional[str]) -> List[Dict[str, Any]]:
        """Return transcript messages captured for an agent."""
        if not agent_id:
            return []

        with self._lock:
            return list(self._messages.get(agent_id, []))

    def clear(self, agent_id: str) -> None:
        """Delete stored audio for an agent."""
        if not agent_id:
            return

        path = self._path_for_agent(agent_id)
        with self._lock:
            self._metadata.pop(agent_id, None)
            self._messages.pop(agent_id, None)
            path.unlink(missing_ok=True)

    def cleanup_old(self, max_age_seconds: int = DEFAULT_MAX_AGE_SECONDS) -> None:
        """Remove stale audio files to avoid unbounded local storage growth."""
        cutoff = time.time() - max_age_seconds
        with self._lock:
            stale_agent_ids = [
                agent_id
                for agent_id, metadata in self._metadata.items()
                if float(metadata.get("updated_at", 0)) < cutoff
            ]

            for agent_id in stale_agent_ids:
                path = Path(str(self._metadata.get(agent_id, {}).get("path", "")))
                self._metadata.pop(agent_id, None)
                self._messages.pop(agent_id, None)
                if path:
                    path.unlink(missing_ok=True)

    def _path_for_agent(self, agent_id: str) -> Path:
        safe_agent_id = SAFE_AGENT_ID.sub("_", agent_id)
        return self.base_dir / f"{safe_agent_id}.pcm"


session_audio_store = SessionAudioStore()
