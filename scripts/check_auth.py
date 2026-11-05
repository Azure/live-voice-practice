"""Verify the required Container Apps browser authentication boundary before deployment."""

import argparse
import json
import os
import shutil
import subprocess
from typing import Any


def validate_platform_auth(properties: dict[str, Any], secret_names: set[str]) -> None:
    """Reject missing provider, token store, credentials, or platform enforcement."""
    tenant = os.environ["AUTH_TENANT_ID"]
    audience = os.environ["AUTH_AUDIENCE"]
    provider = properties.get("identityProviders", {}).get("azureActiveDirectory", {})
    registration = provider.get("registration", {})
    validation = properties.get("globalValidation", {})
    token_store = properties.get("login", {}).get("tokenStore", {})
    scopes = provider.get("login", {}).get("loginParameters", [])
    credential = registration.get("clientSecretSettingName")
    token_secret = token_store.get("azureBlobStorage", {}).get("sasUrlSettingName")
    checks = {
        "Enable Container Apps authentication": properties.get("platform", {}).get("enabled") is True,
        "Require HTTPS": properties.get("httpSettings", {}).get("requireHttps") is True,
        "Enable the Entra provider": provider.get("enabled") is True,
        "Configure the web client ID": bool(registration.get("clientId")),
        "Use the configured tenant's v2 issuer": registration.get("openIdIssuer")
        == f"https://login.microsoftonline.com/{tenant}/v2.0",
        "Reference an existing web client secret": bool(credential) and credential in secret_names,
        "Require authentication at the platform": validation.get("unauthenticatedClientAction")
        in ("Return401", "RedirectToLoginPage"),
        "Exclude only the readiness endpoint": set(validation.get("excludedPaths", [])) <= {"/api/health"},
        "Enable the provider token store": token_store.get("enabled") is True,
        "Reference an existing token-store secret": bool(token_secret) and token_secret in secret_names,
        "Request the delegated API scope": any(
            isinstance(parameter, str)
            and parameter.startswith("scope=")
            and {"openid", "profile", "offline_access", f"api://{audience}/access_as_user"}
            <= set(parameter.removeprefix("scope=").split())
            for parameter in scopes
        ),
    }
    missing = [message for message, passed in checks.items() if not passed]
    if missing:
        raise ValueError("Authentication preflight failed: " + ". ".join(missing) + ". See docs/authentication.md")


def main() -> None:
    """Inspect settings without reading secret values or changing Azure resources."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--resource-group", required=True)
    args = parser.parse_args()
    executable = shutil.which("az")
    if not executable:
        raise RuntimeError("Azure CLI is required for authentication preflight.")

    def read_settings(command: list[str]) -> Any:
        result = subprocess.run(
            [executable, *command, "--name", args.name, "--resource-group", args.resource_group, "-o", "json"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(
                "Cannot read Container Apps authentication settings. Check CLI access and configuration."
            )
        return json.loads(result.stdout)

    properties = read_settings(["containerapp", "auth", "show"])
    properties = properties.get("properties", properties)
    secrets = read_settings(["containerapp", "show", "--query", "properties.configuration.secrets[].name"])
    validate_platform_auth(properties, set(secrets or []))


if __name__ == "__main__":
    main()
