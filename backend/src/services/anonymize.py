# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Trainee identity anonymization for trainer-facing surfaces.

When the program-wide ``SHOW_TRAINEE_IDENTITIES`` flag is ``false`` every
trainer-facing response must hide trainee names/emails and replace the raw
``user_id`` with a stable opaque label (``Trainee #<hash6>``). The hash is a
salted SHA-256 digest so the same trainee resolves to the same label across
endpoints, and the per-environment salt prevents trivial enumeration of the
(often low-entropy) object IDs.
"""

import copy
import hashlib
from typing import Any, Dict, Iterable, Optional

from src.config import config

IDENTITY_PREFIX = "Trainee #"
_HASH_LENGTH = 6


def identities_visible() -> bool:
    """Return True when trainee identities may be shown to trainers."""
    return bool(config.get("show_trainee_identities", True))


def user_hash(user_id: str) -> str:
    """Return a short, deterministic, salted hash for a user id."""
    salt = str(config.get("trainee_hash_salt", ""))
    digest = hashlib.sha256(f"{salt}:{user_id}".encode("utf-8")).hexdigest()
    return digest[:_HASH_LENGTH]


def trainee_label(user_id: str) -> str:
    """Return the opaque display label for a user id (``Trainee #<hash6>``)."""
    return f"{IDENTITY_PREFIX}{user_hash(user_id)}"


def resolve_user_hash(value: str, candidate_user_ids: Iterable[str]) -> Optional[str]:
    """Resolve an opaque hash (or full label) back to a raw user id.

    Hashing is one-way, so resolution is done by hashing each known candidate
    and matching. ``value`` may be either the bare ``<hash6>`` or the full
    ``Trainee #<hash6>`` label.

    Args:
        value: The opaque hash or label coming from a client request.
        candidate_user_ids: The set of user ids currently in scope.

    Returns:
        The matching raw user id, or None if no candidate matches.
    """
    target = value[len(IDENTITY_PREFIX) :] if value.startswith(IDENTITY_PREFIX) else value
    for user_id in candidate_user_ids:
        if user_hash(user_id) == target:
            return user_id
    return None


def anonymize_conversation_record(conversation: Dict[str, Any]) -> Dict[str, Any]:
    """Return a trainer-safe copy of a conversation honoring the identity flag.

    When identities are visible the conversation is returned unchanged. When
    hidden, the raw ``user_id`` is replaced with the opaque hash, a
    ``user_label`` display field is added, and ``metadata.user_name`` /
    ``metadata.user_email`` are stripped.
    """
    if identities_visible():
        return conversation

    sanitized = copy.deepcopy(conversation)
    raw_user_id = sanitized.get("user_id", "")
    if raw_user_id:
        sanitized["user_id"] = user_hash(raw_user_id)
        sanitized["user_label"] = trainee_label(raw_user_id)

    metadata = sanitized.get("metadata")
    if isinstance(metadata, dict):
        metadata.pop("user_name", None)
        metadata.pop("user_email", None)

    return sanitized


def anonymize_trainee_row(row: Dict[str, Any]) -> Dict[str, Any]:
    """Return a trainer-safe copy of a per-trainee aggregate row.

    When identities are hidden the raw ``userId`` is replaced with the opaque
    hash and ``displayName`` becomes the ``Trainee #<hash6>`` label.
    """
    if identities_visible():
        return row

    sanitized = dict(row)
    raw_user_id = sanitized.get("userId", "")
    if raw_user_id:
        sanitized["displayName"] = trainee_label(raw_user_id)
        sanitized["userId"] = user_hash(raw_user_id)
    return sanitized
