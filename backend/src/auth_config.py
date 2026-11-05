"""Authentication configuration checks shared by runtime and deployment hooks."""

import os
from urllib.parse import urlparse
from uuid import UUID


def validate_auth_configuration() -> None:
    """Require a fixed tenant, API audience, and safe browser origin."""
    tenant = os.environ.get("AUTH_TENANT_ID", "")
    try:
        if str(UUID(tenant)) != tenant:
            raise ValueError("Noncanonical tenant")
    except ValueError as error:
        raise RuntimeError("AUTH_TENANT_ID must be an explicit, canonical Entra tenant UUID") from error
    if not os.environ.get("AUTH_AUDIENCE", ""):
        raise RuntimeError("AUTH_AUDIENCE is required")
    origin = urlparse(os.environ.get("AUTH_PUBLIC_ORIGIN", ""))
    local = origin.hostname in ("localhost", "127.0.0.1")
    if (
        not origin.netloc
        or origin.username
        or origin.password
        or origin.query
        or origin.fragment
        or origin.path
        or (origin.scheme != "https" and not (local and origin.scheme == "http"))
    ):
        raise RuntimeError("AUTH_PUBLIC_ORIGIN must be an HTTPS origin (HTTP loopback allowed for local development)")


if __name__ == "__main__":
    validate_auth_configuration()
