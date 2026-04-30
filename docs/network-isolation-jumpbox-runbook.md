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

Need to extend the allow-list for your scenario (e.g. internal artifact feed)? Use [scripts/add-jumpbox-fw-rules.ps1](../scripts/add-jumpbox-fw-rules.ps1):

```powershell
./scripts/add-jumpbox-fw-rules.ps1 -ResourceGroup <rg-name> -SubscriptionId <sub-guid>
```

Run it **after** `azd provision` completes — the firewall policy is locked while provision is in-flight (`FirewallPolicyUpdateFailed: ... 1 faulted referenced firewalls`).

---

## Connect to the jumpbox

1. Azure Portal → resource group → **`testvm<token>`**.
2. **Connect → Bastion**.
3. Admin user: see `azd env get-value VM_ADMIN_USERNAME`. If you didn't set the password during provision, reset it via the portal.
4. Open the Bastion clipboard panel so you can paste env values.

The jumpbox boots with the AILZ bootstrap installed: Azure CLI, `azd`, Git, PowerShell 7, Python 3.11, Bicep CLI, and the AILZ repo cloned at `C:\github\bicep-ptn-aiml-landing-zone`. Extra repos can be added via `manifest.json#components` (see [`infra/README.md`](../infra/README.md)).

---

## Re-running the post-provision hook (jumpbox)

```powershell
cd C:\github\live-voice-practice    # clone the repo on first use
git pull
azd env refresh                      # pull deployment outputs into the local .env
pwsh -NoProfile -File .\scripts\postProvision.ps1
# When asked: "Are you running this script from inside the VNet or via VPN? [Y/n]"  → Y
```

Idempotent. Re-run any time you need to re-apply data-plane steps (e.g. after Cosmos / Search schema changes).

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
- Scripts: [scripts/postProvision.ps1](../scripts/postProvision.ps1) · [scripts/setup_search_dataplane.ps1](../scripts/setup_search_dataplane.ps1) · [scripts/seed_cosmos_samples.py](../scripts/seed_cosmos_samples.py) · [scripts/add-jumpbox-fw-rules.ps1](../scripts/add-jumpbox-fw-rules.ps1)
