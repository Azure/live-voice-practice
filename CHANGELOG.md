# Changelog

All notable changes to this project will be documented in this file.
This format follows Keep a Changelog and adheres to Semantic Versioning.

## [Unreleased]

## [v0.0.2]

### Added
- **Voice WebSocket keep-alive ping** (`frontend/src/hooks/useRealtime.ts`, `backend/src/services/websocket_handler.py`). The client now sends a small `client.ping` message every 25 s while a session is active; the backend proxy answers with `proxy.pong` and does *not* forward the ping to the upstream Voice Live API (avoiding session pollution). This keeps the client↔proxy WebSocket from being closed by the Application Gateway / Container Apps ingress idle timeout, so the reconnect path below is now a fallback for real network drops rather than the common-case idle expiry — the user no longer perceives a reconnect "reload" after leaving the page idle.
- **Automatic voice WebSocket reconnect with exponential backoff** (`frontend/src/hooks/useRealtime.ts`). If the voice connection still drops (real network failure or upstream restart), the client now attempts to reconnect automatically (up to 8 attempts, 1s → 30s backoff) instead of leaving the avatar in a frozen state where `Start Recording` silently does nothing.
- User-visible reconnect status messages surfaced through the existing connection-status callback (e.g., `Voice connection dropped — reconnecting in 2s (attempt 2/8)`, `Voice connection restored`, `Unable to reconnect after several attempts. Please refresh the page to resume.`).
- Automatic avatar WebRTC re-initialization on reconnect: the reopened WebSocket re-sends `session.update`, which causes the backend to re-emit ICE servers via `session.updated`; `App.tsx`'s existing handler then rebuilds the `RTCPeerConnection` through `useWebRTC.setupWebRTC` (which already tears down the prior peer connection safely). No additional app-level wiring required.
- **Avatar reconnect overlay.** During reconnect the avatar panel now shows the regular loading overlay (spinner + stage label) instead of a frozen black video frame. Implemented by mapping the new `voiceSocket: 'reconnecting'` signal back to the `connecting` stage and resetting `startedAt` so the existing `isVideoReady` gate reapplies, plus clearing the dead `srcObject` inside `setupWebRTC` when the peer connection is rebuilt.

### Changed
- Frontend release version bumped to `v0.0.2` (`frontend/src/app/App.tsx`).
- `main.parameters.json`: `searchServiceLocation` default now falls back to `${AZURE_LOCATION}` instead of being hard-coded to `swedencentral`. Set `AZURE_SEARCH_LOCATION` explicitly only when you need the AI Search service to live in a different region than the rest of the deployment.

### Changed
- **Authentication is now Entra ID only across the entire solution; no account / admin / connection-string keys are read or generated anywhere.**
  - Backend (`SupportMaterialsSearchService`, `ConversationManager`, `ScenarioManager`) always uses `DefaultAzureCredential`. The optional `AZURE_SEARCH_API_KEY` and `COSMOS_KEY` config entries were removed.
  - `scripts/setup_search_dataplane.ps1` / `.sh` now upload sample blobs with `az storage --auth-mode login`, drive the Search REST APIs with `az rest --resource https://search.azure.com` (AAD bearer), and configure indexer datasources with `ResourceId=...` connection strings backed by the Search service's system-assigned managed identity. The script also grants the Search MI `Storage Blob Data Reader` on the Storage account.
  - `scripts/seed_cosmos_samples.py` switched from `COSMOS_KEY` to `DefaultAzureCredential` (requires `Cosmos DB Built-in Data Contributor` on the Cosmos account).
- Infra submodule bumped to `bicep-ptn-aiml-landing-zone` **v1.1.0** (ACR Task agent pool + complete jumpbox firewall allow-list). `.gitmodules` and `manifest.json` updated accordingly.
- `scripts/deploy.ps1` and `scripts/deploy.sh` now build and push with `az acr build` instead of `docker buildx`. Under `NETWORK_ISOLATION=true` they use the VNet-attached ACR Tasks agent pool (`ACR_TASK_AGENT_POOL` azd output from v1.1.0); otherwise they use the shared Microsoft-managed pool. **No Docker is required on the workstation or jumpbox anymore.**
- `scripts/postProvision.ps1` and `scripts/postProvision.sh` no longer invoke `add-jumpbox-fw-rules.ps1`. v1.1.0 ships the complete jumpbox bootstrap FQDN allow-list by default via the landing zone's `extendFirewallForJumpboxBootstrap` parameter.
- Infra consumption updated to `bicep-ptn-aiml-landing-zone` **v1.1.9** (`.gitmodules` branch + `manifest.json` `ailz_tag`) and runbooks were refreshed for the upstream certificate-flow hardening: deterministic jumpbox win-acme bootstrap, ACME/firewall expectations, and pre-granted `Key Vault Certificates Officer` on jumpbox MI.

### Removed
- Hard requirement for Docker / `docker buildx` on the machine running `azd deploy`. The network-isolation abort in both deploy scripts is gone — network-isolated deploys now run unchanged from any workstation with ARM egress.
- `scripts/add-jumpbox-fw-rules.ps1` (superseded by v1.1.0 of the landing zone, which ships the complete jumpbox bootstrap allow-list out of the box and no longer needs Docker Hub egress).

## [v1.0.0] – YYYY-MM-DD

### Added
- Azure deployment compatibility with tenants that enforce `disableLocalAuth=true`.
- Managed identity (MSI/Entra ID) authentication fallback for Azure OpenAI calls in conversation analysis.
- Managed identity (MSI/Entra ID) authentication fallback for Azure OpenAI calls in Graph scenario generation.
- Managed identity (MSI/Entra ID) authentication fallback for Azure Voice Live WebSocket connections.
- Speech endpoint configuration (`AZURE_SPEECH_ENDPOINT`) for keyless Speech SDK auth.
- Speech RBAC assignment (`Cognitive Services Speech User`) for container app managed identity.
- Unit tests for keyless Speech config path and websocket credential fallback.

### Changed
- `infra/resources.bicep` no longer uses `listKeys()` for AI Foundry/Speech secrets in container app settings.
- Container app environment variables now prioritize endpoint + managed identity over static API keys.
- Speech and AI region variables now use deployment `location` consistently.
- Frontend realtime connection now opens only after agent creation (`agent_id` available), preventing duplicate websocket sessions.
- Backend websocket log handling now treats early client disconnect before `session.update` as informational instead of error.
- `infra/deployment.json` regenerated from latest Bicep templates to keep ARM output aligned.

### Fixed
- `azd provision` / `azd up` failures with `BadRequest: Failed to list key. disableLocalAuth is set to be true`.
- Resource deployment conflicts caused by stale key-based auth path in infrastructure templates.
- Scenario start flow instability caused by an initial websocket connection without agent context.

### Validated
- Backend unit tests passing (`88 passed`).
- Azure provisioning success after fixes (`azd provision`).
- Full cloud workflow success after fixes (`azd up`) including container app endpoint publication.

