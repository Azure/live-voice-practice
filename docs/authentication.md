# Required Microsoft Entra authentication

Practice, voice, analysis, conversation history, and training administration require
sign-in. Anonymous practice is no longer supported. Caller identity is validated
by the application using signed Microsoft Entra **access tokens**, not identity
headers or an ID token. The backend's managed identity authenticates the backend
to Azure services; it does not authenticate a browser user.

## Required configuration

Set these values in the selected `azd` environment before deploying:

```bash
azd env set AUTH_TENANT_ID "<single Entra tenant UUID>"
azd env set AUTH_AUDIENCE "<API application client ID>"
azd env set AUTH_PUBLIC_ORIGIN "https://<public app hostname>"
```

`AUTH_TENANT_ID` must be a canonical lowercase UUID. `AUTH_AUDIENCE` is the audience
of the delegated v2 access token issued **for this API**, never Microsoft Graph.
`AUTH_PUBLIC_ORIGIN` is exactly the externally accessed origin, including any
non-default port, with no trailing slash, path, query, or fragment. HTTPS is
required except for `http://localhost:<port>` or `http://127.0.0.1:<port>` in local
development. Do not configure a client-provided or forwarded origin dynamically.

The application fails startup if any setting is missing or invalid. Both
`scripts/deploy.ps1` and `scripts/deploy.sh`, invoked by `azd deploy`, validate the
settings before building and pass them to Container Apps together with the image.
Deployment hosts need Python 3 for this configuration check. Before building,
both hooks also run `scripts/check_auth.py` to verify that the existing platform
provider requires authentication, uses HTTPS and the configured tenant, requests
the delegated API scope, and references configured client and token-store
secrets. Only `/api/health` may be excluded from platform authentication.
Missing settings stop deployment with explicit setup instructions. The check
reads secret names, never secret values. Application registration and consent
remain administrator prerequisites, not credentials created by the deploy hook.
The hooks enforce single-revision mode and one replica when updating the image.
The supplied Docker entrypoint runs one Python application process. Infrastructure
is a separately versioned submodule; do not invent a submodule revision to apply
application configuration. A provisioned but unconfigured image will not become
ready. Authentication provider setup below must be completed before browser use.

## Entra application and Container Apps provider

An administrator must configure a single-tenant API application registration:

1. Set `api.requestedAccessTokenVersion` to `2`.
2. Expose a delegated scope named `access_as_user`, usually
   `api://<API-client-ID>/access_as_user`. Grant and consent to that permission for
   the web client. Do not substitute `openid`, `profile`, or Graph permissions.
3. Configure the Container Apps built-in Entra provider (Easy Auth) with the
   tenant-specific issuer and its web client registration. Add the exact redirect
   URI `https://<public-host>/.auth/login/aad/callback` to the web registration.
   Store the web client credential in the platform's secret configuration, never
   in this repository.
4. Enable the provider's token store with its Azure Blob storage SAS secret
   reference. Configure its login parameters to request
   `openid profile offline_access api://<API-client-ID>/access_as_user`.
   Confirm `/.auth/me` returns an `access_token` for the API, with `ver=2.0`,
   `tid=<tenant>`, `aud=<API-client-ID>`, and `scp` containing `access_as_user`.
   An ID token is not accepted. If the provider returns only an ID token or a
   Graph access token, correct the provider scope and consent; do not weaken the
   API validation.
5. Require authentication in the platform as defense in depth. The application
   validates caller credentials independently even when the platform is bypassed.
   Permit only the intended tenant. Keep TLS certificate verification enabled.
   If external readiness probes are used, exclude only `/api/health` from the
   platform login requirement so the deployment smoke check can read its minimal
   status response without an interactive login.

The backend fetches signing keys only from the fixed tenant's Microsoft login
JWKS endpoint and validates RS256 signature, issuer, audience, tenant, expiry,
not-before, object ID, delegated scope, and token version. Network-isolated
deployments must allow outbound HTTPS to `login.microsoftonline.com`; key-discovery
failure denies access.

## Browser and API protocol

The browser reads the provider's access token only in memory and exchanges it via
same-origin `POST /api/auth/session`. The response sets an opaque HttpOnly,
Secure, SameSite=Strict `__Host-voice-session` cookie. Tokens never go into URLs,
local storage, session storage, logs, or WebSocket subprotocols. Browser API calls
and `/ws/voice` use this cookie. Non-browser API clients can instead use
`Authorization: Bearer <API-access-token>`.

Cookie-authenticated mutations require the exact configured `Origin`.
WebSockets also require that origin, authentication before upgrade, and an owned
agent in the first `session.update` message before an Azure connection is opened.
Subsequent session configuration changes are not allowed; voice configuration is
server managed. HTTP requests are limited to 4 MiB and WebSocket frames to 1 MiB.
Delete completed agents to release their temporary state. Session audio and
transcripts are bounded.
Each agent admits one voice connection at a time. Connections close when their
session is revoked or expires, the agent is deleted, or the 15-minute voice lease
ends; reconnecting requires authorization again.

Application browser sessions expire after at most one hour, never beyond token
expiry. `POST /api/auth/logout` revokes the cookie session before platform logout.
Session state, live agent ownership, and audio are local to the application
process. Use **one replica and one application worker** for this release. Restart,
scale-out, or worker changes invalidate active sessions; reauthenticate and create
a fresh agent. Multi-replica use requires a shared server-side session and agent
registry with atomic ownership checks; sticky routing alone is not sufficient.

For local development set the three variables before starting the backend. The
backend must serve the public origin (or be behind a same-origin development
proxy). Real bearer clients can test locally using a delegated API token.
Unit tests use local signing keys and mocked provider services and need no Azure
credentials. Never add a development authentication bypass to deployed code.

## Ownership, trainer access, and upgrades

New ownership keys are `tenant-ID:object-ID`, derived solely from verified claims.
Agent/session creation binds ownership on the server. Conversation creation must
include its owned `agent_id`; when analysis supplies both an agent and a
conversation, they must refer to the same context. Client-provided owner IDs have
no authority. Only the owner can mutate session audio, connect, append messages,
or analyze a conversation.

The signed `admin` application role allows authorized cross-owner conversation
read/deletion. Trainer access is resolved from the trusted Cosmos
`role_assignments` container using the **tenant-scoped key** and retains
anonymized history/statistics/export and content-management behavior. Only
authorized operators may write role assignments. Privileged access remains
within the configured tenant and never includes ownerless records.

Before upgrading:

1. Configure the API, web provider, required settings, consent, and network egress.
2. Back up persistent data through your approved administrative process.
3. Stop old workers and invalidate all old in-memory sessions.
4. Recreate trainer assignments using verified tenant-scoped IDs.
5. Quarantine pre-existing records whose owner is missing or an unscoped ID.
   They are not accessible through the application, including privileged views.
   Do not automatically claim or reassign records using a caller-supplied ID.
   An operator may migrate only after independently establishing both the tenant
   and object ID from authoritative records; otherwise delete under the relevant
   retention policy. No automatic migration is provided.
6. Deploy through `azd deploy`, then separately approve and perform your normal
   environment validation. Local tests do not establish deployment or rollout.

The SPA, `/api/config`, `/api/health`, and unauthenticated `/api/me` are public;
they expose no conversation content. All other API routes are authenticated.
