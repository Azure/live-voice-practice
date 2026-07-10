# Changelog

All notable changes to this project will be documented in this file.
This format follows Keep a Changelog and adheres to Semantic Versioning.

## [Unreleased]

## [1.1.2] - 2026-07-10

### Fixed
- Pronunciation assessment no longer returns 0.0 for every score on real multi-turn sessions. The assessor now uses continuous recognition in unscripted (reference-less) mode, aggregates each recognized phrase weighted by word count, and logs `result.reason` on non-`RecognizedSpeech` events so `NoMatch` outcomes are visible instead of being silently reported as all-zero scores. A 90 s bounded timeout on continuous recognition prevents the analyze flow from hanging when the SDK never emits `session_stopped`. Fixes #55.

## [1.1.1] - 2026-06-22

### Added
- Replaced the README architecture section with the new Live Voice Practice architecture diagram and added the editable Visio source download link.
- Added admin chart help tooltips and score-aware colors so low-scoring results are clearly visible instead of appearing as successful green states.
- Added admin transcript fallback for built-in sample transcripts so sample scenarios and rubrics reference transcripts that are visible in Admin.

### Changed
- Reworked the setup screen so it no longer blocks navigation like a modal.
- Improved the scenario and rubric admin forms with clearer sections, row-based support materials and criteria, better helper text, and stronger save labels.
- Standardized visible product wording to use "Live Voice Agent" instead of "avatar".
- Standardized user-facing date formatting across admin and conversation screens.
- Reduced overly wide chart bars for sparse data.

### Fixed
- Scoring now retries transient model failures and surfaces diagnostics when asynchronous scoring cannot complete.
- Admin scenario and rubric metadata no longer renders raw ISO timestamps.
- The default chat deployment capacity is now 50, avoiding immediate capacity bottlenecks in the test deployment.

## [1.1.0] - 2026-06-22

### Added
- Realtime function/tool calling for locally-hosted agents (`backend/src/services/voice_tools.py`, `backend/src/services/websocket_handler.py`). The proxy now advertises a `get_scenario_context` tool in the Voice Live session for non-Azure agents, handles the `response.function_call_arguments.done` event, dispatches the call against the active scenario, and returns the result with a `FunctionCallOutputItem` followed by `response.create`. The model can ask for the current scenario name and description mid-conversation instead of relying only on the static system prompt. Azure-hosted agents are untouched because they manage their own tools. Gated by the new `ENABLE_REALTIME_FUNCTION_CALLING` config (default on).
- `AZURE_VOICE_API_VERSION` config knob (`backend/src/config.py`) so the Voice Live API version can be overridden per environment without a code change. Defaults to the new `2026-01-01-preview`.

### Changed
- Voice Live API version bumped from `2025-05-01-preview` to `2026-01-01-preview` (`backend/src/services/websocket_handler.py`, `AZURE_VOICE_API_VERSION`). The value is also overridable via the `AZURE_VOICE_API_VERSION` config for backward compatibility if a subscription does not yet expose the new version.
- Realtime model deployment parameterized in `main.parameters.json`. The realtime `modelDeployment` now uses `${REALTIME_MODEL_NAME=gpt-realtime-1.5}` and `${REALTIME_MODEL_VERSION=2026-02-23}` so an operator can point to a different Foundry catalog name and version at provision time without editing the template. The default stays on the latest cataloged realtime model, `gpt-realtime-1.5`. When a newer realtime model appears in the Foundry catalog for the target subscription, adopt it with `azd env set REALTIME_MODEL_NAME <name>` (and `REALTIME_MODEL_VERSION <version>`).
- Input speech transcription is now configurable instead of hard-coded to `whisper-1` (`backend/src/services/websocket_handler.py`). The session reads `AZURE_INPUT_TRANSCRIPTION_MODEL` (default `azure-speech`) and `AZURE_INPUT_TRANSCRIPTION_LANGUAGE` (default `en-US`). Operators adopting MAI-Transcribe set the exact catalog name through `AZURE_INPUT_TRANSCRIPTION_MODEL` with no code change. This also resolves a latent inconsistency where the code sent `whisper-1` while config already declared `azure-speech` as the default.
- Infra consumption pin realigned to `bicep-ptn-aiml-landing-zone` `v2.0.14` (`manifest.json` `ailz_tag`). The `.gitmodules` branch and the submodule gitlink already pointed at `v2.0.14` (commit `90e78a9`); only `manifest.json` was stale at `v1.1.9`. `.gitmodules` and `manifest.json` now agree.

### Notes
- Model and voice names are surfaced as overridable config defaults rather than hard-coded in backend code, so an operator can adopt a newer name with `azd env set` once it appears in the Foundry catalog, and a wrong realtime name fails fast at provision time. The verified catalog defaults in this release are `gpt-realtime-1.5` (realtime), `en-US-Ava:DragonHDLatestNeural` (avatar voice), and `azure-speech` (input transcription). Names announced at Build 2026 such as `MAI-Voice-2` / `Voice-2-Flash` (text to speech) and `MAI-Transcribe-1.5` (speech to text) are not yet listed as Voice Live models; set them through the matching config knob only after confirming availability for your subscription. Native noise reduction, echo cancellation, semantic VAD turn detection, and avatar settings are unchanged and remain valid under the new API version.

## [v0.0.2]

### Added
- **Voice WebSocket keep-alive ping** (`frontend/src/hooks/useRealtime.ts`, `backend/src/services/websocket_handler.py`). The client now sends a small `client.ping` message every 25 s while a session is active; the backend proxy answers with `proxy.pong` and does *not* forward the ping to the upstream Voice Live API (avoiding session pollution). This keeps the client↔proxy WebSocket from being closed by the Application Gateway / Container Apps ingress idle timeout, so the reconnect path below is now a fallback for real network drops rather than the common-case idle expiry — the user no longer perceives a reconnect "reload" after leaving the page idle.
- **Automatic voice WebSocket reconnect with exponential backoff** (`frontend/src/hooks/useRealtime.ts`). If the voice connection still drops (real network failure or upstream restart), the client now attempts to reconnect automatically (up to 8 attempts, 1s → 30s backoff) instead of leaving the avatar in a frozen state where `Start Recording` silently does nothing.
- User-visible reconnect status messages surfaced through the existing connection-status callback (e.g., `Voice connection dropped — reconnecting in 2s (attempt 2/8)`, `Voice connection restored`, `Unable to reconnect after several attempts. Please refresh the page to resume.`).
- Automatic avatar WebRTC re-initialization on reconnect: the reopened WebSocket re-sends `session.update`, which causes the backend to re-emit ICE servers via `session.updated`; `App.tsx`'s existing handler then rebuilds the `RTCPeerConnection` through `useWebRTC.setupWebRTC` (which already tears down the prior peer connection safely). No additional app-level wiring required.
- **Avatar reconnect overlay.** During reconnect the avatar panel now shows the regular loading overlay (spinner + stage label) instead of a frozen black video frame. Implemented by mapping the new `voiceSocket: 'reconnecting'` signal back to the `connecting` stage and resetting `startedAt` so the existing `isVideoReady` gate reapplies, plus clearing the dead `srcObject` inside `setupWebRTC` when the peer connection is rebuilt.

### Changed
- **Optional public ingress is now strictly opt-in, even under network isolation** (amendment to v0.0.2): `main.parameters.json` now defaults `publicIngress.enabled` to `"${PUBLIC_INGRESS_ENABLED=false}"` (previously `"${PUBLIC_INGRESS_ENABLED=${NETWORK_ISOLATION=false}}"`). Under the previous default, turning on `NETWORK_ISOLATION=true` also turned on the optional Application Gateway WAF v2 ingress, which is a cost-bearing resource (~USD 240/month for the gateway alone) and is not needed when operators reach the workload through the jumpbox / Bastion session, an Azure Virtual Desktop deployed in the spoke, or an ExpressRoute/VPN into the VNet. The Application Gateway is now **only deployed when `PUBLIC_INGRESS_ENABLED=true` is set explicitly**. README, deployment guide, public-ingress runbook, and network-isolation runbook were updated end-to-end so the public-ingress runbook is documented as conditional on opting in (it is not applicable to deployments that don't set `PUBLIC_INGRESS_ENABLED=true`). No infra/Bicep contract change — the upstream landing zone (`Azure/bicep-ptn-aiml-landing-zone`) `publicIngressType` already defaulted to `{ enabled: false }`; this fix realigns the consumer overlay with that contract.

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
