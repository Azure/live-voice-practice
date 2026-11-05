"""Authentication and resource authorization regressions using local signing keys."""

import base64
import json
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from src.app import app
from src.services import auth
from src.services.websocket_handler import VoiceProxyHandler
from src.services.database import ConversationStore

TENANT = "11111111-1111-1111-1111-111111111111"
OID = "33333333-3333-3333-3333-333333333333"
OWNER = f"{TENANT}:{OID}"
OTHER = f"{TENANT}:44444444-4444-4444-4444-444444444444"
ORIGIN = "https://voice.example"


@pytest.fixture
def credentials(monkeypatch):
    """Provide an actual RSA signature verifier without network discovery."""
    monkeypatch.setenv("AUTH_TENANT_ID", TENANT)
    monkeypatch.setenv("AUTH_AUDIENCE", "api-test")
    monkeypatch.setenv("AUTH_PUBLIC_ORIGIN", ORIGIN)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    client = Mock()
    client.get_signing_key_from_jwt.return_value = SimpleNamespace(key=key.public_key())
    monkeypatch.setattr(auth, "_jwks_client", client)
    now = int(time.time())
    claims = {
        "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0",
        "aud": "api-test",
        "tid": TENANT,
        "oid": OID,
        "ver": "2.0",
        "scp": "access_as_user",
        "iat": now,
        "nbf": now - 1,
        "exp": now + 600,
    }

    def token(omit=None, **overrides):
        payload = {**claims, **overrides}
        if omit:
            payload.pop(omit)
        return jwt.encode(payload, key, algorithm="RS256")

    return token


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with auth._session_lock:
        auth._sessions.clear()
    return app.test_client()


@pytest.mark.parametrize(
    "changes",
    [
        {"exp": 1},
        {"nbf": int(time.time()) + 3600},
        {"aud": "wrong"},
        {"iss": "https://evil.example"},
        {"tid": "wrong"},
        {"oid": ""},
        {"scp": "openid"},
        {"ver": "1.0"},
        {"roles": "admin"},
    ],
)
def test_invalid_tokens_fail_closed(credentials, changes):
    with pytest.raises(jwt.PyJWTError):
        auth.validate_access_token(credentials(**changes))


def test_valid_token_and_signature_rejection(credentials):
    assert auth.validate_access_token(credentials())["oid"] == OID
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    claims = jwt.decode(credentials(), options={"verify_signature": False})
    with pytest.raises(jwt.InvalidSignatureError):
        auth.validate_access_token(jwt.encode(claims, key, algorithm="RS256"))
    with pytest.raises(jwt.InvalidAlgorithmError):
        auth.validate_access_token(jwt.encode(claims, "", algorithm="none"))
    with pytest.raises(jwt.MissingRequiredClaimError):
        auth.validate_access_token(credentials(omit="oid"))


@pytest.mark.parametrize("claim", ["exp", "iat", "nbf", "iss", "aud", "tid", "oid", "scp"])
def test_required_claims_are_mandatory(credentials, claim):
    with pytest.raises(jwt.MissingRequiredClaimError):
        auth.validate_access_token(credentials(omit=claim))


def test_signing_key_discovery_failure_denies_access(client, credentials):
    token = credentials()
    auth._jwks_client.get_signing_key_from_jwt.side_effect = jwt.PyJWKClientConnectionError("Offline fixture")
    with patch("src.app.agent_manager") as agents:
        assert (
            client.post(
                "/api/agents/create",
                json={},
                headers={
                    "Authorization": f"Bearer {token}",
                },
            ).status_code
            == 401
        )
        assert not agents.mock_calls


@pytest.mark.parametrize(
    "method,path",
    [
        ("get", "/api/conversations/foreign"),
        ("delete", "/api/conversations/foreign"),
        ("patch", "/api/conversations/foreign/messages"),
        ("post", "/api/analyze"),
        ("post", "/api/agents/create"),
        ("delete", "/api/agents/foreign"),
        ("post", "/api/conversations"),
        ("get", "/api/admin/statistics/overview"),
        ("get", "/api/admin/statistics/export"),
        ("get", "/api/admin/scenarios"),
        ("post", "/api/scenarios/graph"),
    ],
)
def test_fabricated_headers_never_reach_protected_services(client, method, path):
    principal = base64.b64encode(
        json.dumps(
            {
                "claims": [{"typ": "oid", "val": OID}, {"typ": "roles", "val": "admin"}],
            }
        ).encode()
    ).decode()
    with (
        patch("src.app.conversation_store") as store,
        patch("src.app.session_audio_store") as audio,
        patch("src.app.agent_manager") as agents,
        patch("src.app.conversation_analyzer") as analyzer,
        patch("src.services.role_store.role_store") as roles,
    ):
        response = getattr(client, method)(
            path,
            json={},
            headers={
                "x-ms-client-principal": principal,
                "x-ms-client-principal-id": OID,
            },
        )
        assert response.status_code == 401
        for service in (store, audio, agents, analyzer, roles):
            assert not service.mock_calls


@pytest.mark.parametrize("owner", [OTHER, None, "legacy-user"])
def test_foreign_agent_rejected_before_audio_or_azure(client, credentials, owner):
    with (
        patch("src.app.agent_manager") as agents,
        patch("src.app.session_audio_store") as audio,
        patch("src.app.conversation_analyzer") as analyzer,
        patch("src.app.conversation_store") as store,
    ):
        agents.get_agent.return_value = {"owner_id": owner}
        headers = {"Authorization": f"Bearer {credentials()}"}
        for method, path, body in [
            ("post", "/api/analyze", {"agent_id": "foreign", "scenario_id": "test"}),
            ("delete", "/api/agents/foreign", {}),
        ]:
            response = getattr(client, method)(path, json=body, headers=headers)
            assert response.status_code == 404
            assert response.json == {"error": "Resource not found"}
        audio.assert_not_called()
        assert not audio.mock_calls
        assert not analyzer.mock_calls
        assert not store.mock_calls
        agents.delete_agent.assert_not_called()


def test_conversation_rejection_precedes_analysis(client, credentials):
    with (
        patch("src.app.conversation_store") as store,
        patch("src.app.session_audio_store") as audio,
        patch("src.app.conversation_analyzer") as analyzer,
    ):
        store.get_conversation.return_value = None
        headers = {"Authorization": f"Bearer {credentials()}"}
        assert (
            client.post(
                "/api/analyze",
                json={
                    "conversation_id": "foreign",
                    "scenario_id": "test",
                },
                headers=headers,
            ).status_code
            == 404
        )
        assert client.patch("/api/conversations/foreign/messages", json={}, headers=headers).status_code == 404
        assert not audio.mock_calls
        assert not analyzer.mock_calls
        store.update_conversation_messages.assert_not_called()


def test_browser_session_origin_cookie_logout(client, credentials):
    token = credentials()
    assert client.post("/api/auth/session", json={"access_token": token}).status_code == 403
    response = client.post("/api/auth/session", json={"access_token": token}, headers={"Origin": ORIGIN})
    assert response.status_code == 200
    assert all(value in response.headers["Set-Cookie"] for value in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/"))
    assert token not in response.headers["Set-Cookie"]
    assert client.get("/api/me").json["user_id"] == OWNER
    assert client.post("/api/agents/create", json={}).status_code == 401
    assert client.post("/api/auth/logout", headers={"Origin": ORIGIN}).status_code == 200
    assert client.get("/api/me").json == {"authenticated": False}


def test_expired_cookie_cannot_read_or_use_cloud(client, credentials):
    assert (
        client.post(
            "/api/auth/session",
            json={
                "access_token": credentials(),
            },
            headers={"Origin": ORIGIN},
        ).status_code
        == 200
    )
    with auth._session_lock:
        for key, (claims, _) in auth._sessions.items():
            auth._sessions[key] = (claims, time.time() - 1)
    with patch("src.app.agent_manager") as agents, patch("src.app.conversation_store") as store:
        assert client.get("/api/me").json == {"authenticated": False}
        assert client.get("/api/conversations").status_code == 401
        assert client.post("/api/agents/create", json={}, headers={"Origin": ORIGIN}).status_code == 401
        assert not agents.mock_calls
        assert not store.mock_calls


def test_ownerless_privileged_access_rejected():
    user = auth.UserIdentity(OWNER, roles=["admin"], role="trainer")
    assert user.can_access_user_data(OTHER)
    assert not user.can_access_user_data("")
    assert not user.can_access_user_data(OID)
    assert not user.can_access_user_data("other-tenant:" + OID)


@pytest.mark.asyncio
@pytest.mark.parametrize("owner", [OTHER, None])
async def test_websocket_rejects_foreign_before_upstream(owner):
    agents = Mock()
    agents.get_agent.return_value = {"owner_id": owner}
    handler = VoiceProxyHandler(agents)
    ws = Mock()
    ws.receive.return_value = json.dumps({"type": "session.update", "session": {"agent_id": "foreign"}})
    with patch("src.services.websocket_handler.connect") as connect:
        await handler.handle_connection(ws, OWNER, lambda: True)
        connect.assert_not_called()
        assert ws.close.called


@pytest.mark.asyncio
async def test_websocket_session_switch_is_not_forwarded():
    handler = VoiceProxyHandler(Mock())
    ws = Mock()
    ws.receive.return_value = json.dumps({"type": "session.update", "session": {"agent_id": "foreign"}})
    upstream = AsyncMock()
    await handler._forward_client_to_azure(ws, upstream, "owned", lambda: True)
    upstream.send.assert_not_called()
    ws.close.assert_called_once()


@pytest.mark.asyncio
async def test_revoked_voice_lease_stops_audio_before_storage_or_upstream():
    handler = VoiceProxyHandler(Mock())
    ws = Mock()
    ws.receive.return_value = json.dumps({"type": "input_audio_buffer.append", "audio": "c2VjcmV0"})
    upstream = AsyncMock()
    with patch("src.services.websocket_handler.session_audio_store") as audio:
        await handler._forward_client_to_azure(ws, upstream, "owned", lambda: False)
        assert not audio.mock_calls
        upstream.send.assert_not_called()
        ws.close.assert_called_once()


def test_websocket_handshake_rejects_before_handler(client):
    with patch("src.app.voice_proxy_handler") as handler:
        assert client.get("/ws/voice", headers={"Origin": "https://evil.example"}).status_code == 403
        assert client.get("/ws/voice", headers={"Origin": ORIGIN}).status_code == 401
        assert not handler.mock_calls


@pytest.mark.parametrize("name", ["AUTH_TENANT_ID", "AUTH_AUDIENCE", "AUTH_PUBLIC_ORIGIN"])
def test_missing_configuration_fails_startup(monkeypatch, name):
    monkeypatch.delenv(name, raising=False)
    with pytest.raises(RuntimeError):
        auth.validate_auth_configuration()


def test_legitimate_owner_lifecycle_and_bound_context(client, credentials):
    headers = {"Authorization": f"Bearer {credentials()}"}
    agent = {"scenario_id": "test", "owner_id": OWNER}
    record = {"id": "conversation", "scenario_id": "test", "user_id": OWNER}
    with (
        patch("src.app.agent_manager") as agents,
        patch("src.app.scenario_manager") as scenarios,
        patch("src.app.conversation_store") as store,
        patch("src.app.session_audio_store") as audio,
        patch("src.app._perform_conversation_analysis") as analyze,
    ):
        agents.agents = {}

        def create(*_args):
            agents.agents["agent"] = agent
            return "agent"

        agents.create_agent.side_effect = create
        agents.get_agent.return_value = agent
        scenarios.get_scenario.return_value = {"id": "test"}
        store.create_conversation.return_value = "conversation"
        store.get_conversation.return_value = record
        store.update_conversation_messages.return_value = True
        analyze.return_value = {"ai_assessment": {"score": 80}}
        assert client.post("/api/agents/create", json={"scenario_id": "test"}, headers=headers).status_code == 200
        assert agents.agents["agent"]["owner_id"] == OWNER
        assert client.post(
            "/api/conversations",
            json={
                "scenario_id": "test",
                "agent_id": "agent",
                "user_id": OTHER,
            },
            headers=headers,
        ).json == {"conversation_id": "conversation"}
        assert store.create_conversation.call_args.kwargs["user_id"] == OWNER
        assert agent["conversation_id"] == "conversation"
        assert (
            client.patch(
                "/api/conversations/conversation/messages",
                json={
                    "messages": [],
                },
                headers=headers,
            ).status_code
            == 200
        )
        audio.get_user_audio.return_value = None
        assert (
            client.post(
                "/api/analyze",
                json={
                    "scenario_id": "test",
                    "agent_id": "agent",
                    "conversation_id": "conversation",
                    "transcript": "Hello",
                },
                headers=headers,
            ).status_code
            == 200
        )
        analyze.assert_called_once()
        analyze.reset_mock()
        agent["conversation_id"] = "different"
        audio.reset_mock()
        assert (
            client.post(
                "/api/analyze",
                json={
                    "scenario_id": "test",
                    "agent_id": "agent",
                    "conversation_id": "conversation",
                },
                headers=headers,
            ).status_code
            == 404
        )
        analyze.assert_not_called()
        assert not audio.mock_calls
        assert client.delete("/api/agents/agent", headers=headers).status_code == 200
        audio.clear.assert_called_once_with("agent")


@pytest.mark.parametrize("role", ["admin", "trainer"])
def test_verified_privileged_conversation_flow(client, credentials, role):
    headers = {"Authorization": f"Bearer {credentials(roles=['admin'] if role == 'admin' else [])}"}
    with patch("src.app.conversation_store") as store, patch("src.app.role_store") as roles:
        roles.get_user_role.return_value = role
        store.get_conversation.return_value = None
        store.get_conversation_by_id_admin.return_value = {"id": "conversation", "user_id": OTHER}
        store.delete_conversation.return_value = True
        assert client.get("/api/conversations/conversation", headers=headers).status_code == 200
        assert client.delete("/api/conversations/conversation", headers=headers).status_code == 200
        store.delete_conversation.assert_called_once_with(user_id=OTHER, conversation_id="conversation")
        store.get_conversation_by_id_admin.return_value = {"id": "conversation"}
        assert client.get("/api/conversations/conversation", headers=headers).status_code == 404
        assert client.delete("/api/conversations/conversation", headers=headers).status_code == 404
        assert store.delete_conversation.call_count == 1


def test_database_delete_cannot_skip_ownership():
    store = ConversationStore()
    store._initialized = True
    store._container = Mock()
    store._container.read_item.return_value = {"user_id": OTHER}
    assert not store.delete_conversation(OWNER, "foreign")
    store._container.delete_item.assert_not_called()
    store._container.read_item.return_value = {"user_id": OWNER}
    assert store.delete_conversation(OWNER, "owned")
    store._container.delete_item.assert_called_once()


@pytest.mark.asyncio
async def test_owned_websocket_connects_and_uses_server_config():
    agents = Mock()
    agents.get_agent.return_value = {"owner_id": OWNER}
    handler = VoiceProxyHandler(agents)
    ws = Mock()
    ws.receive.return_value = json.dumps({"type": "session.update", "session": {"agent_id": "owned"}})
    connection = AsyncMock()
    manager = AsyncMock()
    manager.__aenter__.return_value = connection
    handler._send_initial_config = AsyncMock()
    handler._handle_message_forwarding = AsyncMock()
    with (
        patch("src.services.websocket_handler.connect", return_value=manager) as connect,
        patch.object(handler, "_get_credential", return_value=Mock()),
    ):
        await handler.handle_connection(ws, OWNER, lambda: True)
        connect.assert_called_once()
        handler._send_initial_config.assert_awaited_once()
        handler._handle_message_forwarding.assert_awaited_once()
        assert not handler._active_agents


@pytest.mark.asyncio
async def test_expired_websocket_never_connects():
    agents = Mock()
    agents.get_agent.return_value = {"owner_id": OWNER}
    handler = VoiceProxyHandler(agents)
    ws = Mock()
    ws.receive.return_value = json.dumps({"type": "session.update", "session": {"agent_id": "owned"}})
    with patch("src.services.websocket_handler.connect") as connect:
        await handler.handle_connection(ws, OWNER, lambda: False)
        connect.assert_not_called()


@pytest.mark.parametrize("body", [[], "invalid", {"agent_id": ["invalid"]}])
def test_invalid_payloads_rejected_after_authentication(client, credentials, body):
    assert client.post("/api/analyze", json=body).status_code == 401
    assert (
        client.post(
            "/api/analyze",
            json=body,
            headers={
                "Authorization": f"Bearer {credentials()}",
            },
        ).status_code
        == 400
    )
