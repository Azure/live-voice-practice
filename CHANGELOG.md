# Changelog

All notable changes to this project will be documented in this file.
This format follows Keep a Changelog and adheres to Semantic Versioning.

## [Unreleased]

### Changed
- Infra submodule bumped to `bicep-ptn-aiml-landing-zone` **v1.1.0** (ACR Task agent pool + complete jumpbox firewall allow-list). `.gitmodules` and `manifest.json` updated accordingly.
- `scripts/deploy.ps1` and `scripts/deploy.sh` now build and push with `az acr build` instead of `docker buildx`. Under `NETWORK_ISOLATION=true` they use the VNet-attached ACR Tasks agent pool (`ACR_TASK_AGENT_POOL` azd output from v1.1.0); otherwise they use the shared Microsoft-managed pool. **No Docker is required on the workstation or jumpbox anymore.**
- `scripts/postProvision.ps1` and `scripts/postProvision.sh` no longer invoke `add-jumpbox-fw-rules.ps1`. v1.1.0 ships the complete jumpbox bootstrap FQDN allow-list by default via the landing zone's `extendFirewallForJumpboxBootstrap` parameter.

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

