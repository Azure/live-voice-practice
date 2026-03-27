# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Authentication service for extracting user identity from Azure Easy Auth headers."""

import base64
import json
import logging
from dataclasses import dataclass
from functools import wraps
from typing import Any, Callable, Dict, List, Optional

from flask import g, request

logger = logging.getLogger(__name__)

# Azure Easy Auth header names
HEADER_CLIENT_PRINCIPAL = "x-ms-client-principal"
HEADER_CLIENT_PRINCIPAL_ID = "x-ms-client-principal-id"
HEADER_CLIENT_PRINCIPAL_NAME = "x-ms-client-principal-name"

# Admin role name - users with this role can access all conversations
ADMIN_ROLE = "admin"


@dataclass
class UserIdentity:
    """Represents an authenticated user's identity."""

    user_id: str
    name: Optional[str] = None
    email: Optional[str] = None
    roles: Optional[List[str]] = None
    role: str = "trainee"

    @property
    def is_admin(self) -> bool:
        """Check if the user has admin role."""
        return self.roles is not None and ADMIN_ROLE in self.roles

    @property
    def is_trainer(self) -> bool:
        """Check if the user has trainer role."""
        return self.role == "trainer"

    def can_access_user_data(self, target_user_id: str) -> bool:
        """Check if this user can access another user's data."""
        return self.user_id == target_user_id or self.is_admin or self.is_trainer


def get_current_user() -> Optional[UserIdentity]:
    """Get the current authenticated user from the request context.

    Returns:
        UserIdentity object if user is authenticated, None otherwise.
    """
    # Check if user is already cached in request context
    if hasattr(g, "current_user"):
        return g.current_user

    user = _extract_user_from_headers()
    g.current_user = user
    return user


def _extract_user_from_headers() -> Optional[UserIdentity]:
    """Extract user identity from Azure Easy Auth headers.

    Azure Easy Auth sets the following headers:
    - x-ms-client-principal: Base64-encoded JSON with user claims
    - x-ms-client-principal-id: User's unique identifier (object ID)
    - x-ms-client-principal-name: User's display name or email

    Returns:
        UserIdentity object if headers are present, None otherwise.
    """
    # Try to get the full principal first (has more information)
    principal_header = request.headers.get(HEADER_CLIENT_PRINCIPAL)

    if principal_header:
        try:
            decoded = base64.b64decode(principal_header)
            principal_data: Dict[str, Any] = json.loads(decoded)
            return _parse_principal_data(principal_data)
        except (ValueError, json.JSONDecodeError) as e:
            logger.warning("Failed to decode client principal: %s", e)

    # Fallback to simple headers if full principal is not available
    user_id = request.headers.get(HEADER_CLIENT_PRINCIPAL_ID)
    if user_id:
        name = request.headers.get(HEADER_CLIENT_PRINCIPAL_NAME)
        return UserIdentity(user_id=user_id, name=name)

    return None


def _parse_principal_data(data: Dict[str, Any]) -> UserIdentity:
    """Parse the decoded principal data into a UserIdentity object.

    The principal data structure from Azure Easy Auth:
    {
        "auth_typ": "aad",
        "claims": [
            {"typ": "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier", "val": "..."},
            {"typ": "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress", "val": "..."},
            {"typ": "name", "val": "..."},
            {"typ": "http://schemas.microsoft.com/ws/2008/06/identity/claims/role", "val": "admin"},
            ...
        ],
        "name_typ": "...",
        "role_typ": "..."
    }
    """
    claims = {claim["typ"]: claim["val"] for claim in data.get("claims", [])}

    # Extract user ID (object ID is preferred)
    user_id = claims.get(
        "http://schemas.microsoft.com/identity/claims/objectidentifier",
        claims.get(
            "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier",
            claims.get("oid", ""),
        ),
    )

    # Extract name
    name = claims.get("name", claims.get("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"))

    # Extract email
    email = claims.get(
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
        claims.get("preferred_username", claims.get("email")),
    )

    # Extract roles - roles can appear multiple times
    roles: List[str] = []
    role_claim_type = "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"
    for claim in data.get("claims", []):
        if claim["typ"] == role_claim_type:
            roles.append(claim["val"])

    return UserIdentity(user_id=user_id, name=name, email=email, roles=roles if roles else None)


def require_auth(f: Callable[..., Any]) -> Callable[..., Any]:
    """Decorator to require authentication for a route.

    Usage:
        @app.route('/api/protected')
        @require_auth
        def protected_route():
            user = get_current_user()
            return f"Hello, {user.name}"
    """

    @wraps(f)
    def decorated_function(*args: Any, **kwargs: Any) -> Any:
        user = get_current_user()
        if user is None:
            from flask import jsonify

            return jsonify({"error": "Authentication required"}), 401
        return f(*args, **kwargs)

    return decorated_function
