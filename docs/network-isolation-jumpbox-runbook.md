# Network Isolation — Jumpbox quick reference

> The full step-by-step deployment procedure (basic and network-isolated) lives
> in [deployment.md](deployment.md). **Start there.** This page is a quick
> reference for operators already familiar with the workflow: subnet layout,
> firewall allow-list, troubleshooting tips, and the “what runs where” split.

---

## What runs where

| Step | Workstation | Jumpbox (in-VNet) | Notes |
|------|:-----------:|:----------------:|-------|
| `azd auth login` / `az login` | ✅ | ✅ | Both, with the same tenant. |
| `azd provision` (control plane: ARM/Bicep) | ✅ | ➖ | Public ARM endpoints; runs from the workstation. |
| `postprovision` hook — ACR endpoint persistence + Container App registry binding | ✅ | ✅ | ARM-only; runs in both. |
| `postprovision` hook — App Configuration data-plane writes | ❌ | ✅ | Private endpoint only. |
| `postprovision` hook — AI Search data-plane (skillset/index/indexer) | ❌ | ✅ | Private endpoint only. |
| `postprovision` hook — Cosmos sample seed | ❌ | ✅ | Private endpoint only. |
| `azd deploy` (image build + Container App update) | ❌ | ✅ | Build runs on the **ACR Tasks `build-pool` agent pool** inside the VNet; no Docker on the jumpbox. |
| Open the app FQDN in a browser | ❌ | ✅ | Container App ingress is internal-only. |

The hook auto-detects the situation:

- `NETWORK_ISOLATION=false` → all steps run inline on the workstation.
- `NETWORK_ISOLATION=true` + non-interactive (azd hook in CI / from `azd provision`) → data-plane steps **skipped** with a printed reminder.
- `NETWORK_ISOLATION=true` + interactive on the jumpbox → prompts `Are you running this script from inside the VNet or via VPN? [Y/n]`. Answer `Y` to apply data-plane steps.

---

## Network layout

| Subnet | Default CIDR | Purpose |
|--------|--------------|---------|
| `AzureBastionSubnet` | `192.168.2.64/26` | Bastion host. |
| `AzureFirewallSubnet` | `192.168.2.0/26` | Azure Firewall data plane. |
| `jumpbox-subnet` | `192.168.3.64/27` | `testvm<token>` Windows Server jumpbox. |
| `pe-subnet` | `192.168.0.0/24` | Private endpoints for ACR, App Config, KV, Cosmos, Search, Speech, Foundry, Storage. |
| `agents-subnet` | `192.168.4.0/24` | ACR Tasks `build-pool` (in-VNet image builds). |
| `aca-environment-subnet` | `192.168.5.0/24` | Container Apps Environment. |

Egress from the jumpbox + ACR Tasks subnets is forced through Azure Firewall (`afw-<token>` / `afwp-<token>`).

---

## Firewall allow-list (jumpbox bootstrap)

Defined upstream in `_firewallVmBootstrapFqdns` (AILZ `main.bicep`). Ships with v1.1.4+:

- Microsoft / Windows update: `*.update.microsoft.com`, `*.windowsupdate.com`, `download.windowsupdate.com`
- Tooling installers: `aka.ms`, `go.microsoft.com`, `download.microsoft.com`, `*.azureedge.net`, `*.core.windows.net`
- Chocolatey: `chocolatey.org`, `*.chocolatey.org`, `nuget.org`, `*.nuget.org`, `dist.nuget.org`, `dl.bintray.com`
- Visual Studio installer: `aka.ms/vs/...`, `download.visualstudio.microsoft.com`
- GitHub: `github.com`, `*.github.com`, `objects.githubusercontent.com`, `*.githubusercontent.com`, `codeload.github.com`
- **Bicep CLI bootstrap** (added in v1.1.4 / issue #36): `downloads.bicep.azure.com`
- Speech FQDNs (added when `deploySpeechService=true`): `*.cognitiveservices.azure.com`, `*.tts.speech.microsoft.com`, `*.stt.speech.microsoft.com`

Need to extend the allow-list for your scenario (e.g. internal artifact feed)? Edit the AILZ submodule's `_firewallVmBootstrapFqdns` (or the dedicated `extendFirewallForJumpboxBootstrap` parameter introduced in v1.1.0) and re-run `azd provision` from the workstation. The standalone `add-jumpbox-fw-rules.ps1` helper that used to live under `scripts/` was removed once v1.1.0 of the landing zone shipped the complete jumpbox bootstrap allow-list out of the box.

---

## Connect to the jumpbox

1. Azure Portal → resource group → **`testvm<token>`**.
2. **Connect → Bastion**.
3. Admin user: see `azd env get-value VM_ADMIN_USERNAME`. If you didn't set the password during provision, reset it via the portal.
4. Open the Bastion clipboard panel so you can paste env values.

The jumpbox boots with the AILZ bootstrap installed: Azure CLI, `azd`, Git, PowerShell 7, Python 3.11, Bicep CLI, and the AILZ repo cloned at `C:\github\bicep-ptn-aiml-landing-zone`. Extra repos can be added via `manifest.json#components` (see [`infra/README.md`](../infra/README.md)).

---

## Re-running the post-provision hook (jumpbox)

The repo is pre-cloned by the AILZ bootstrap (via `manifest.json#components`), but the `infra/` submodule is **not** initialized — do that on first use.

```powershell
cd C:\github\live-voice-practice
git pull
git submodule update --init --recursive   # first run only
az login --identity                        # use the jumpbox MI (no env refresh needed; .env is pre-populated by AILZ bootstrap)
pwsh -NoProfile -File .\scripts\postProvision.ps1
# When asked: "Are you running this script from inside the VNet or via VPN? [Y/n]"  → Y
```

Idempotent. Re-run any time you need to re-apply data-plane steps (e.g. after Cosmos / Search schema changes).

---

## Manual UI testing (microphone limitation)

The jumpbox is intended for **bootstrap and admin tasks**, not as a workstation for exercising the app's voice features. **Azure Bastion does not redirect audio input** — neither the HTML5 client nor the native client (`az network bastion rdp`) forward the local microphone into the VM. The Bastion gateway drops the audio capture virtual channel before it reaches the RDP host. Source: [Azure Bastion - Remote audio](https://learn.microsoft.com/en-us/azure/bastion/vm-about#remote-audio) — *"Audio input is not supported at the moment."*

Practical consequence: the **avatar renders correctly** inside an Edge session on the jumpbox (audio output works), but **`Start Recording` reports "Microphone unavailable"** — no VM-side or `.rdp` configuration changes this.

### Recommended path — Application Gateway public ingress (deployer-controlled, BYO domain + cert)

Since [Azure/bicep-ptn-aiml-landing-zone#49](https://github.com/Azure/bicep-ptn-aiml-landing-zone/issues/49) shipped in the upstream landing zone (`v1.1.6`) and was adopted by this accelerator, the network-isolated deployment **automatically** provisions an Application Gateway WAF v2 in **skeleton mode** in front of the internally posted Container App: the gateway, Public IP, WAF policy, and a deny-all NSG are provisioned, but the HTTPS listener has no cert and the NSG allows no source. This is by design — the operator completes the security-relevant bits (domain + cert + IP allow-list) in a separate, fast, reversible step.

To complete the configuration and reach the app from a real workstation with a real microphone, follow the deployer-side runbook:

➡ [`docs/manual-testing/public-ingress-runbook.md`](manual-testing/public-ingress-runbook.md)

The runbook covers domain registration, certificate acquisition (illustrative path: certbot manual DNS-01 + a publicly trusted free CA), Key Vault import, the `azd env set` calls that promote the gateway from skeleton to live mode, validation, renewals, and teardown. The architectural rationale is captured in [ADR-0001](adr/0001-manual-testing-microphone-application-gateway.md) and [ADR-0002](adr/0002-bring-your-own-domain-and-certificate.md).

### Alternative paths

If you do not want to expose the app publicly, three alternatives preserve the deny-by-default posture:

| Option | Approach | Notes |
|--------|----------|-------|
| **Point-to-Site VPN** | Add a P2S VPN gateway to the hub VNet; connect from your local PC; resolve the Container App's private FQDN via the VNet's private DNS; use the local browser (with local mic) to reach the app. | Preserves network isolation entirely. One-time gateway cost (~USD 30/month for VpnGw1). |
| **Direct RDP via temporary public IP on the VM** | Attach a public IP to the jumpbox, lock the NSG to your egress IP on 3389, RDP with `mstsc` directly (not through Bastion). Native RDP forwards mic normally. | Cheapest. Exposes RDP — keep the window short and remove the public IP afterwards. |
| **Azure Virtual Desktop** | Replace the jumpbox with an AVD session host. AVD supports full audio I/O redirection. | Heavier. Use only if you need ongoing manual UI testing in an isolated environment. |

The avatar (audio output) requires no special action beyond what Bicep already provisions — it works inside Bastion sessions because only the playback channel is needed.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `azd provision` fails with `OperationNotAllowed: Cannot modify extensions in the VM when the VM is not running` | The jumpbox is deallocated. `az vm start -g <rg> -n testvm<token>` and re-run `azd provision`. |
| `azd env refresh` fails with `Failed: Downloading Bicep` from the jumpbox | The firewall is missing `downloads.bicep.azure.com` in the bootstrap allow-list. Verify `git -C infra describe --tags` is `v1.1.4+`. If you're stuck on an older tag and can't bump, set `AZURE_DEV_USE_INSTALLED_BICEP=true` and pre-install Bicep (`winget install Microsoft.Bicep`). |
| `az appconfig kv set ... 403 ip-address-rejected` | You're outside the VNet. Re-run `postProvision.ps1` from the jumpbox. |
| `Resolve-DnsName <name>.azconfig.io` (or any `.privatelink.*`) returns a public IP from the jumpbox | The DNS zone link is missing or the OS resolver cache is stale. Verify `az network private-dns link vnet list -g <rg> -z privatelink.azconfig.io`, then `Restart-Computer` on the VM. |
| `az acr build` returns `agent pool not found` | The ACR Tasks pool failed to provision. Check `az acr agentpool show -r <acr> -n build-pool -g <rg>`. The pool needs the dedicated `agents-subnet` and the registry must be Premium. |
| Cosmos seed fails with `ResourceNotFound` | Cosmos PE still propagating; wait ~60s and re-run the hook. |
| Container App revision stuck in `Provisioning` | `az containerapp logs show ... --type system`. Most failures are missing `AcrPull` on the Container App MI (Bicep grants it; verify role assignment exists). |
| Speech REST returns `AccountCustomSubDomainNameNotSet` | Should not happen with AILZ v1.1.4+ (Bicep sets `customSubDomainName=speechServiceName`). If you see it, delete + purge the Speech account and re-run `azd provision`. |

---

## Reference

- Full deployment guide: [docs/deployment.md](deployment.md)
- AI Search dataplane runbook: [docs/ai-search-indexing-runbook.md](ai-search-indexing-runbook.md)
- AILZ submodule: [`infra/`](../infra/)
- Scripts: [scripts/postProvision.ps1](../scripts/postProvision.ps1) · [scripts/setup_search_dataplane.ps1](../scripts/setup_search_dataplane.ps1) · [scripts/seed_cosmos_samples.py](../scripts/seed_cosmos_samples.py)
