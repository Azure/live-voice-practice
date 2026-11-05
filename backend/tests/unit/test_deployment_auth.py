"""Cloud-free tests for deployment admission checks."""

import importlib.util
import json
from copy import deepcopy
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

SPEC = importlib.util.spec_from_file_location(
    "check_auth", Path(__file__).resolve().parents[3] / "scripts" / "check_auth.py"
)
assert SPEC is not None and SPEC.loader is not None
check_auth = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_auth)


@pytest.fixture
def platform_config(monkeypatch):
    """Return a valid platform provider configuration without credentials."""
    monkeypatch.setenv("AUTH_TENANT_ID", "tenant")
    monkeypatch.setenv("AUTH_AUDIENCE", "api")
    return {
        "platform": {"enabled": True},
        "httpSettings": {"requireHttps": True},
        "globalValidation": {"unauthenticatedClientAction": "Return401", "excludedPaths": ["/api/health"]},
        "identityProviders": {
            "azureActiveDirectory": {
                "enabled": True,
                "registration": {
                    "clientId": "web",
                    "clientSecretSettingName": "web-secret",
                    "openIdIssuer": "https://login.microsoftonline.com/tenant/v2.0",
                },
                "login": {"loginParameters": ["scope=openid profile offline_access api://api/access_as_user"]},
            }
        },
        "login": {"tokenStore": {"enabled": True, "azureBlobStorage": {"sasUrlSettingName": "token-secret"}}},
    }


def test_valid_platform_auth(platform_config):
    check_auth.validate_platform_auth(platform_config, {"web-secret", "token-secret"})


@pytest.mark.parametrize(
    "path,value",
    [
        (("platform", "enabled"), False),
        (("httpSettings", "requireHttps"), False),
        (("globalValidation", "unauthenticatedClientAction"), "AllowAnonymous"),
        (("globalValidation", "excludedPaths"), ["/api/*"]),
        (("identityProviders", "azureActiveDirectory", "enabled"), False),
        (("identityProviders", "azureActiveDirectory", "registration", "openIdIssuer"), "https://wrong"),
        (("identityProviders", "azureActiveDirectory", "registration", "clientId"), ""),
        (("identityProviders", "azureActiveDirectory", "login", "loginParameters"), ["scope=openid profile"]),
        (("login", "tokenStore", "enabled"), False),
    ],
)
def test_incomplete_platform_auth_fails_closed(platform_config, path, value):
    config = deepcopy(platform_config)
    target = config
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    with pytest.raises(ValueError, match="Authentication preflight failed"):
        check_auth.validate_platform_auth(config, {"web-secret", "token-secret"})


def test_missing_secret_fails_closed(platform_config):
    with pytest.raises(ValueError, match="existing"):
        check_auth.validate_platform_auth(platform_config, set())


def test_preflight_reads_names_only(platform_config, monkeypatch):
    runner = Mock(
        side_effect=[
            SimpleNamespace(returncode=0, stdout=json.dumps({"properties": platform_config})),
            SimpleNamespace(returncode=0, stdout='["web-secret", "token-secret"]'),
        ]
    )
    monkeypatch.setattr(check_auth.subprocess, "run", runner)
    monkeypatch.setattr(check_auth.shutil, "which", lambda _: "az")
    monkeypatch.setattr("sys.argv", ["check_auth.py", "--name", "voice", "--resource-group", "test"])
    check_auth.main()
    commands = [call.args[0] for call in runner.call_args_list]
    assert commands[0][1:4] == ["containerapp", "auth", "show"]
    assert commands[1][1:5] == ["containerapp", "show", "--query", "properties.configuration.secrets[].name"]
    assert all("list-secrets" not in command for command in commands)


def test_cli_failure_stops_preflight_without_echoing_output(monkeypatch):
    runner = Mock(return_value=SimpleNamespace(returncode=1, stdout="sensitive", stderr="sensitive"))
    monkeypatch.setattr(check_auth.subprocess, "run", runner)
    monkeypatch.setattr(check_auth.shutil, "which", lambda _: "az")
    monkeypatch.setattr("sys.argv", ["check_auth.py", "--name", "voice", "--resource-group", "test"])
    with pytest.raises(RuntimeError, match="Cannot read") as error:
        check_auth.main()
    assert "sensitive" not in str(error.value)
    runner.assert_called_once()
