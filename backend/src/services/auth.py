"""Server-validated Entra identities and short-lived browser sessions."""

import os
import secrets
import threading
import time
from dataclasses import dataclass
from functools import wraps
from typing import Any, Callable, List, Optional
from uuid import UUID

import jwt
from flask import g, jsonify, request
from src.auth_config import validate_auth_configuration

COOKIE_NAME = "__Host-voice-session"
_sessions: dict[str, tuple[dict[str, Any], float]] = {}
_session_lock = threading.Lock()
_jwks_client: Optional[jwt.PyJWKClient] = None


@dataclass
class UserIdentity:
    """Identity whose user_id includes the validated tenant and object IDs."""

    user_id: str
    name: Optional[str] = None
    email: Optional[str] = None
    roles: Optional[List[str]] = None
    role: str = "trainee"

    @property
    def is_admin(self) -> bool:
        """Only signed application role claims grant administration."""
        return "admin" in (self.roles or [])

    @property
    def is_trainer(self) -> bool:
        """Trainer assignments are resolved using the tenant-scoped identity."""
        return self.role == "trainer"

    def can_access_user_data(self, target_user_id: str) -> bool:
        """Deny ownerless and legacy unscoped records even to privileged callers."""
        tenant = self.user_id.partition(":")[0]
        return bool(
            isinstance(target_user_id, str)
            and target_user_id
            and target_user_id.startswith(tenant + ":")
            and (self.user_id == target_user_id or self.is_admin or self.is_trainer)
        )


def validate_access_token(token: str) -> dict[str, Any]:
    """Validate a delegated v2 Entra access token against a fixed tenant and API."""
    global _jwks_client  # pylint: disable=global-statement
    validate_auth_configuration()
    tenant = os.environ["AUTH_TENANT_ID"]
    if not token or len(token) > 16384:
        raise jwt.InvalidTokenError("Invalid credential")
    if _jwks_client is None:
        _jwks_client = jwt.PyJWKClient(
            f"https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys",
            timeout=5,
            cache_jwk_set=True,
            lifespan=3600,
        )
    key = _jwks_client.get_signing_key_from_jwt(token).key
    claims = jwt.decode(
        token,
        key,
        algorithms=["RS256"],
        audience=os.environ["AUTH_AUDIENCE"],
        issuer=f"https://login.microsoftonline.com/{tenant}/v2.0",
        options={"require": ["exp", "iat", "nbf", "iss", "aud", "tid", "oid", "scp"]},
    )
    if claims["tid"] != tenant or claims.get("ver") != "2.0":
        raise jwt.InvalidTokenError("Invalid tenant or token version")
    try:
        UUID(claims["oid"])
    except (ValueError, TypeError, AttributeError) as error:
        raise jwt.InvalidTokenError("Invalid identity") from error
    if "access_as_user" not in str(claims["scp"]).split():
        raise jwt.InvalidTokenError("Delegated API scope required")
    if not isinstance(claims.get("roles", []), list):
        raise jwt.InvalidTokenError("Invalid roles")
    return claims


def _identity(claims: dict[str, Any]) -> UserIdentity:
    return UserIdentity(
        user_id=f'{claims["tid"]}:{claims["oid"]}',
        name=claims.get("name"),
        email=claims.get("preferred_username"),
        roles=claims.get("roles", []),
    )


def same_origin() -> bool:
    """Require the configured browser origin, without trusting forwarded headers."""
    return request.headers.get("Origin") == os.environ.get("AUTH_PUBLIC_ORIGIN")


def _cookie_name() -> str:
    return COOKIE_NAME if os.environ.get("AUTH_PUBLIC_ORIGIN", "").startswith("https://") else "voice-local-session"


def create_browser_session(token: str):
    """Exchange a validated access token for an opaque, HttpOnly browser cookie."""
    if not same_origin():
        return jsonify({"error": "Access denied"}), 403
    try:
        claims = validate_access_token(token)
    except (jwt.PyJWTError, ValueError, TypeError):
        return jsonify({"error": "Authentication required"}), 401
    now = time.time()
    expiry = min(float(claims["exp"]), now + 3600)
    session_id = secrets.token_urlsafe(32)
    with _session_lock:
        expired = [key for key, (_, deadline) in _sessions.items() if deadline <= now]
        for key in expired:
            del _sessions[key]
        if len(_sessions) >= 4096:
            return jsonify({"error": "Session capacity reached"}), 503
        old = request.cookies.get(_cookie_name())
        if old:
            _sessions.pop(old, None)
        _sessions[session_id] = (claims, expiry)
    response = jsonify({"authenticated": True})
    response.headers["Cache-Control"] = "no-store"
    response.set_cookie(
        _cookie_name(),
        session_id,
        max_age=max(0, int(expiry - now)),
        secure=os.environ["AUTH_PUBLIC_ORIGIN"].startswith("https://"),
        httponly=True,
        samesite="Strict",
        path="/",
    )
    return response


def get_current_user() -> Optional[UserIdentity]:
    """Resolve bearer credentials or a previously validated server-side session."""
    if hasattr(g, "current_user"):
        return g.current_user
    user = None
    authorization = request.headers.get("Authorization", "")
    if authorization:
        try:
            scheme, token = authorization.split(" ", 1)
            if scheme.lower() == "bearer":
                claims = validate_access_token(token)
                user = _identity(claims)
                g.auth_expires_at = float(claims["exp"])
        except (jwt.PyJWTError, ValueError, TypeError):
            pass
    else:
        with _session_lock:
            saved = _sessions.get(request.cookies.get(_cookie_name(), ""))
        if saved and saved[1] > time.time():
            if request.method in ("GET", "HEAD", "OPTIONS") or same_origin():
                user = _identity(saved[0])
    g.current_user = user
    return user


def websocket_authorizer() -> Callable[[], bool]:
    """Capture a bounded authorization lease without retaining request/token data."""
    deadline = min(getattr(g, "auth_expires_at", time.time() + 900), time.time() + 900)
    if request.headers.get("Authorization"):
        return lambda: time.time() < deadline
    session_id = request.cookies.get(_cookie_name(), "")

    def valid() -> bool:
        with _session_lock:
            saved = _sessions.get(session_id)
        return bool(saved and time.time() < min(deadline, saved[1]))

    return valid


def revoke_browser_session():
    """Revoke this browser's session without logging credentials."""
    if not same_origin():
        return jsonify({"error": "Access denied"}), 403
    with _session_lock:
        _sessions.pop(request.cookies.get(_cookie_name(), ""), None)
    response = jsonify({"authenticated": False})
    response.delete_cookie(
        _cookie_name(), path="/", secure=_cookie_name() == COOKIE_NAME, httponly=True, samesite="Strict"
    )
    response.headers["Cache-Control"] = "no-store"
    return response


def require_auth(function: Callable[..., Any]) -> Callable[..., Any]:
    """Reject unauthenticated callers before the protected handler executes."""

    @wraps(function)
    def decorated(*args: Any, **kwargs: Any) -> Any:
        if get_current_user() is None:
            return jsonify({"error": "Authentication required"}), 401
        return function(*args, **kwargs)

    return decorated


def require_trainer(function: Callable[..., Any]) -> Callable[..., Any]:
    """Resolve trusted trainer assignments only after authentication."""

    @wraps(function)
    def decorated(*args: Any, **kwargs: Any) -> Any:
        from src.services.role_store import role_store

        user = get_current_user()
        if user is None:
            return jsonify({"error": "Authentication required"}), 401
        user.role = role_store.get_user_role(user.user_id)
        if not user.is_trainer:
            return jsonify({"error": "Access denied"}), 403
        return function(*args, **kwargs)

    return decorated
