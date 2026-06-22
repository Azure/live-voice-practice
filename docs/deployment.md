# Deployment Guide

This guide explains how to deploy **Live Voice Practice** to Azure in two modes:

1. **Basic deployment** — public endpoints, no Azure Firewall / Bastion / jumpbox. Fastest path; suitable for development, demos, and personal sandboxes.
2. **Network-isolated (Zero Trust) deployment** — private endpoints, Azure Firewall egress control, all data-plane traffic stays inside the VNet. Required for production-grade environments.

> **Which mode should I read?** To try the app quickly, follow [Mode 1 — Basic deployment](#mode-1--basic-deployment). For production, or any environment that must keep traffic private, follow [Mode 2 — Network-isolated (Zero Trust) deployment](#mode-2--network-isolated-zero-trust-deployment). Either way, read [Prerequisites](#prerequisites-workstation-both-modes) and the [Authentication model](#authentication-model--entra-id-only-no-keys) first.

## Workflow at a glance

| Step | Basic mode | Network-isolated (ZTA) mode |
|------|-----------|------------------------------|
| Provision infra | `azd up` (workstation) | `azd provision` (workstation) |
| Build & deploy the app | included in `azd up` | `azd deploy` from the **jumpbox** *(after `git pull` + submodule init + `az login --identity`)* |
| Data-plane post-provision | runs automatically on your workstation | run `pwsh ./scripts/postProvision.ps1` from the **jumpbox** (private endpoints) |
| Public access (BYO domain + cert) | not applicable | **opt-in.** Set `azd env set PUBLIC_INGRESS_ENABLED true` before `azd provision`, then follow the [public ingress runbook](manual-testing/public-ingress-runbook.md). Skip entirely if you reach the app from the jumpbox / Bastion, an Azure Virtual Desktop in the spoke, or an ExpressRoute/VPN into the VNet. |

`azd up` ≡ `azd provision` followed by `azd deploy`. The `postprovision` hook (`scripts/postProvision.ps1` / `scripts/postProvision.sh`) runs automatically at the end of `azd provision`; in NI mode it auto-skips the data-plane steps because they cannot reach private endpoints from outside the VNet.

For day-to-day iteration:

```powershell
azd deploy      # app code changes (workstation in basic mode, jumpbox in NI mode)
azd provision   # infra/Bicep changes (always from workstation)
```

---

## Defaults and overrides

These are the Bicep parameter defaults you get out of the box. Override any of them with `azd env set <VAR> <value>` **before** you run `azd provision`.

| Setting (Bicep parameter) | Default | Override | What it does |
|---|---|---|---|
| Container App identity (`useUAI`) | System-assigned managed identity (both modes) | `azd env set USE_UAI true` | Switches the Container App to a user-assigned identity. The default works for both modes. |
| ACS media egress firewall rules (`enableAcsMediaEgress`) | Enabled in NI mode (basic mode has no firewall) | `azd env set ENABLE_ACS_MEDIA_EGRESS false` | Opens UDP 3478-3481 / TCP 443+3478-3481 to `AzureCloud` through Azure Firewall so the Speech avatar, ACS Calling, and Teams Media can stream. |
| Application Gateway WAF v2 public ingress (`publicIngress.enabled`) | Disabled, even when `NETWORK_ISOLATION=true` | `azd env set PUBLIC_INGRESS_ENABLED true` | Deploys the public entry point (gateway + Public IP + WAF policy + NSG). Only needed when testers reach the app from the public Internet with a real microphone. See the [public ingress runbook](manual-testing/public-ingress-runbook.md). |
| Realtime model name (`REALTIME_MODEL_NAME` in `main.parameters.json`) | `gpt-realtime-1.5` | `azd env set REALTIME_MODEL_NAME <name>` | Foundry catalog name of the realtime model deployed for the Voice Live session. Defaults to the latest cataloged realtime model. Set a different name (for example a newer `gpt-realtime-*`) once it is listed in the Foundry catalog for your subscription. |
| Realtime model version (`REALTIME_MODEL_VERSION` in `main.parameters.json`) | `2026-02-23` | `azd env set REALTIME_MODEL_VERSION <version>` | Catalog version paired with `REALTIME_MODEL_NAME`. Confirm the exact version for your subscription before provisioning. |

In **basic mode** there is no firewall and the Container App ingress is already public, so the ACS egress and public-ingress rows do not apply.

---

## Runtime configuration keys (App Configuration)

These keys are read by the backend at runtime (App Configuration in Azure, or environment variables locally). Change them without rebuilding the image; restart the Container App revision to pick up new values.

| Key | Default | What it does |
|---|---|---|
| `AZURE_VOICE_API_VERSION` | `2026-01-01-preview` | Voice Live API version used for the realtime session. Override only to pin or roll forward the API surface. |
| `ENABLE_REALTIME_FUNCTION_CALLING` | `true` | Advertises the `get_scenario_context` function tool to the realtime model for locally-hosted (non-Azure) agents. Azure-hosted agents are not affected. Set `false` to disable the tool. |
| `AZURE_INPUT_TRANSCRIPTION_MODEL` | `azure-speech` | Input speech transcription model. Operators adopting MAI-Transcribe set the exact Foundry catalog name here with no code change. |
| `AZURE_INPUT_TRANSCRIPTION_LANGUAGE` | `en-US` | Input speech transcription language. |

> **Foundry catalog names and region.** The verified defaults in this release are `gpt-realtime-1.5` (realtime), `en-US-Ava:DragonHDLatestNeural` (avatar voice), and `azure-speech` (input transcription). Names announced at Build 2026 such as `MAI-Voice-2` / `Voice-2-Flash` (voice) and `MAI-Transcribe-1.5` (transcription) are not yet listed as Voice Live models; adopt them through the matching config knob only after confirming availability for your subscription. For the broadest coverage of the newest Voice Live models, deploy to `swedencentral` (or `eastus2`), which carry `gpt-realtime-1.5` and the latest GPT-5.x models with Voice Live agent support. See [Voice Live supported models and regions](https://learn.microsoft.com/azure/ai-services/speech-service/regions?tabs=voice-live).

---

## Prerequisites (workstation, both modes)

Install on the machine that will run `azd`:

| Tool | Minimum | Notes |
|------|---------|-------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | 2.60+ | `az` |
| [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) | 1.24+ | `azd` |
| [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) | 7.4+ | required by `postProvision.ps1` |
| Python | 3.11+ | required by the Cosmos sample seed |

> **Docker is NOT a prerequisite in either mode.** `scripts/deploy.ps1` (the `predeploy` hook invoked by `azd deploy`) builds and pushes the container image with `az acr build`. The build runs inside Azure Container Registry Tasks — on the Microsoft-managed shared agent pool in basic mode, and on the VNet-attached `build-pool` agent pool in NI mode. Your workstation (and the jumpbox) only ship the build context to ACR; they never run `docker build` locally.

Sign in:

```powershell
az login --tenant <AZURE_TENANT_ID>
az account set --subscription <AZURE_SUBSCRIPTION_ID>
azd auth login --tenant-id <AZURE_TENANT_ID>
```

## Authentication model — Entra ID only (no keys)

This solution does **not** use any account / admin / connection-string keys end-to-end. Every component authenticates via Microsoft Entra ID:

- **Container App** — system-assigned managed identity calls AI Foundry, Speech, Cosmos DB, AI Search, Key Vault, App Configuration and Storage with `DefaultAzureCredential`.
- **AI Search** — system-assigned managed identity is used by indexers/skillsets to read from Storage and call AI Foundry embeddings; the indexer datasource connection string uses the `ResourceId=/subscriptions/.../storageAccounts/<name>;` form (no `AccountKey`).
- **Post-provision scripts** — `scripts/setup_search_dataplane.{ps1,sh}` use `az rest --resource https://search.azure.com` and `az storage --auth-mode login`; `scripts/seed_cosmos_samples.py` uses `DefaultAzureCredential`.

### RBAC is granted by the Bicep template

All role assignments are created at provisioning time by `infra/main.bicep` — there is **no manual `az role assignment create` step** and the post-provision scripts no longer try to grant any role at runtime. The relevant grants include:

| Principal | Role | Target | Bicep module |
|---|---|---|---|
| Container App MI | `AcrPull` | ACR | `assignCrAcrPullContainerApps` |
| Container App MI | `Storage Blob Data Contributor` / `Reader` | Storage account | `assignStorageStorageBlobDataContributorAca` / `…Reader…` |
| Container App MI | `Cosmos DB Built-in Data Contributor` | Cosmos account | `assignCosmosDBCosmosDbBuiltInDataContributorContainerApps` |
| Container App MI | `Search Index Data Contributor` | AI Search | (executor + ACA grants in `main.bicep`) |
| Container App MI | `Cognitive Services User` | Speech / AI Foundry | `assignSpeechCognitiveServicesUser…` |
| Search MI | `Storage Blob Data Reader` | Storage account | `assignStorageStorageBlobDataReaderSearch` |
| Search MI | `Cognitive Services User` | AI Foundry | `assignAiFoundryAccountCognitiveServicesUserSearch` |
| Executor (your dev user / jumpbox MI) | `Storage Blob Data Contributor`, `Search Service Contributor`, `Search Index Data Contributor`, `App Configuration Data Owner`, `Key Vault Secrets Officer`, `Cognitive Services Contributor` | scoped to each resource | `assignExecutorRoles` |
| TestVM MI (jumpbox, NI mode) | `Cosmos DB Built-in Data Contributor` | Cosmos database | `assignCosmosDBCosmosDbBuiltInDataContributorTestVm` |

The executor principal is determined automatically by the Bicep template: it falls back to your dev user in Mode 1, and to the jumpbox VM's system-assigned MI in Mode 2 (NI). As long as you re-run `azd provision` whenever you change identities, the post-provision scripts have everything they need.

---

## Mode 1 — Basic deployment

### 1. Create the azd environment

```powershell
azd env new <env-name>
# optional: pin Azure AI Search to another region
azd env set AZURE_SEARCH_LOCATION northeurope
```

> `azd` will prompt for subscription and location on first run if they are not set; only set them explicitly when you want to override the prompts (e.g. CI). `NETWORK_ISOLATION` defaults to `false`.

> **Recommended region:** `swedencentral` (or `eastus2`) for the broadest Voice Live coverage of `gpt-realtime-1.5` and the latest GPT-5.x models. Pin it with `azd env set AZURE_LOCATION swedencentral`.

### 2. Provision and deploy

```powershell
azd up
```

This will:

1. Provision all resources (Foundry, OpenAI deployments, Speech, Cosmos, AI Search, Storage, ACR, Container Apps Environment, Container App, Key Vault, App Configuration, Application Insights).
2. Run the `postprovision` hook **directly on your workstation**. Because all data-plane endpoints are public in this mode, the hook applies every step inline:
    - persists `AZURE_CONTAINER_REGISTRY_ENDPOINT` and binds the Container App to ACR via system-assigned identity;
    - writes `AZURE_INPUT_TRANSCRIPTION_MODEL=azure-speech` to App Configuration;
    - configures the AI Search data-plane (skillset, index, indexer) via [scripts/setup_search_dataplane.ps1](../scripts/setup_search_dataplane.ps1);
    - seeds Cosmos DB with the sample scenarios/rubrics via [scripts/seed_cosmos_samples.py](../scripts/seed_cosmos_samples.py).
3. Build the container image with `az acr build` running on the **shared Microsoft-managed ACR Tasks agent pool** (no Docker on your workstation), push it to ACR, and roll a new revision of the `voicelab` Container App.

### 3. Iterate

```powershell
# infra changes
azd provision

# app code changes
azd deploy
```

### 4. Validate

```powershell
$rg = azd env get-value AZURE_RESOURCE_GROUP
$ca = az containerapp list -g $rg --query "[0].name" -o tsv
az containerapp show -g $rg -n $ca --query "properties.configuration.ingress.fqdn" -o tsv
```

Open the FQDN in a browser.

---

## Mode 2 — Network-isolated (Zero Trust) deployment

In this mode all data-plane traffic stays inside the VNet:

- ACR is **Premium** with `publicNetworkAccess=Disabled` and reachable only via private endpoint. Image builds run on the in-VNet **ACR Tasks agent pool** (no Docker required on the jumpbox).
- App Configuration, Cosmos DB, Key Vault, AI Search, Speech, Foundry, Storage are all reachable only via private endpoints.
- Egress from the jumpbox subnet is forced through Azure Firewall (FQDN-tag allow-list).
- The Container App ingress is internal — only resolvable from inside the VNet.

See [Authentication model — Entra ID only (no keys)](#authentication-model--entra-id-only-no-keys) above for details on the auth approach used in both modes.

The deployment is split into two phases:

- **Phase A — workstation:** `azd provision` creates infra. The `postprovision` hook runs but **skips** all data-plane steps because they cannot reach private endpoints from your laptop.
- **Phase B — jumpbox:** you connect to the in-VNet jumpbox via Bastion, clone the repo, and re-run the `postprovision` hook (which now can reach the private endpoints), then run `azd deploy` (which uses the ACR Tasks agent pool to build the image inside the VNet).

### Phase A — Provision from your workstation

#### A.1. Create the azd environment

```powershell
azd env new <env-name>
azd env set NETWORK_ISOLATION                    true
azd env set AZURE_SKIP_NETWORK_ISOLATION_WARNING true
# optional: pin Azure AI Search to another region
azd env set AZURE_SEARCH_LOCATION                northeurope
```

> `azd` will prompt for subscription and location on first run if they are not set. Only set `AZURE_LOCATION` / `AZURE_SUBSCRIPTION_ID` explicitly when you want to override the prompt (e.g. CI). `DEPLOY_SPEECH_SERVICE` defaults to `true`.

> **Recommended region:** `swedencentral` (or `eastus2`) for the broadest Voice Live coverage of `gpt-realtime-1.5` and the latest GPT-5.x models. Pin it with `azd env set AZURE_LOCATION swedencentral`.

> The Bastion + Azure Firewall + jumpbox VM are part of the Bicep template (`deployVM=true`, default). The firewall policy is pre-configured with the FQDN allow-list needed to bootstrap the jumpbox (`azd`, Bicep CLI, GitHub, Speech, Foundry, ACR, …).

> Since `infra/` ≥ `v1.1.9`, the optional **Application Gateway WAF v2 public ingress** is available but **disabled by default**, even when `NETWORK_ISOLATION=true`. Network isolation provisions the dedicated `AppGatewaySubnet` regardless, but the gateway/Public IP/WAF policy/NSG are only deployed when you opt in. Opt in only if you need testers to reach the app from a real workstation with a real microphone (or any other public-Internet entry point). Otherwise reach the app from the jumpbox / Bastion, an Azure Virtual Desktop in the spoke, or an ExpressRoute/VPN into the VNet — none of these require the gateway. To enable it, run `azd env set PUBLIC_INGRESS_ENABLED true` before `azd provision`, then follow [docs/manual-testing/public-ingress-runbook.md](manual-testing/public-ingress-runbook.md) to complete the BYO domain + certificate step. The jumpbox bootstrap and RBAC are already prepared for that path (win-acme preinstalled via deterministic asset URL and Key Vault certificate import role pre-granted).

#### A.2. Run provision

```powershell
azd provision
```

Expected console output:

```text
SUCCESS: Your application was provisioned in Azure in <NN> minutes ...
[>] Running post-provision hook...
[>] Zero Trust / Network Isolation enabled.
   [?] Are you running this script from inside the VNet or via VPN? [Y/n]
```

Answer **`n`** (or just leave it for the non-interactive azd hook — the hook auto-skips when stdin is redirected). The hook will report:

```text
[i]  Network isolation is enabled. Three data-plane steps were skipped:
     - App Configuration writes (AZURE_INPUT_TRANSCRIPTION_MODEL)
     - Cosmos sample seed (scenarios/rubrics)
     - Azure AI Search data-plane setup
   Connect to the jumpbox via Bastion ... and run ./scripts/postProvision.ps1
```

This is the expected outcome — **continue to Phase B**.

#### A.3. Capture the values you will need on the jumpbox

```powershell
azd env get-values | Select-String -Pattern 'AZURE_ENV_NAME|AZURE_RESOURCE_GROUP|AZURE_SUBSCRIPTION_ID|AZURE_TENANT_ID|AZURE_LOCATION'
```

Save them somewhere you can paste into the Bastion session (Bastion has a copy/paste toolbar).

### Phase B — Post-provisioning on the jumpbox

#### B.1. Connect to the jumpbox

1. Azure Portal → resource group → **`testvm<token>`** (Windows Server VM on `jumpbox-subnet`).
2. **Connect → Bastion**.
3. Sign in with the admin credentials from `azd env get-value VM_ADMIN_USERNAME` and the password you set (or that the template generated; reset it via the portal if you didn't).

The jumpbox already has the AILZ bootstrap installed: Azure CLI, `azd`, Git, PowerShell 7, Python 3.11, Bicep CLI, the AILZ repo cloned at `C:\github\bicep-ptn-aiml-landing-zone`, **this repo cloned at `C:\github\live-voice-practice`** (via the `manifest.json#components` extension point — the parent repo is checked out but submodules are **not** initialized), and the firewall allow-list opens the FQDNs needed by all of those tools.

#### B.2. Initialize the repo on the jumpbox

The parent repo is already on disk at `C:\github\live-voice-practice`. Pull the latest commit (in case the bootstrap clone is older than the version you provisioned from your workstation) and initialize the `infra/` submodule:

```powershell
cd C:\github\live-voice-practice
git pull
git submodule update --init --recursive
# verify the submodule landed on the expected pin (v2.0.14 = 90e78a9 or newer)
git -C infra describe --tags --always
```

If the repo is **not** already at `C:\github\live-voice-practice` (e.g. you bootstrapped without the `manifest.json#components` entry), clone it manually:

```powershell
cd C:\github
git clone https://github.com/Azure/live-voice-practice.git
cd live-voice-practice
git submodule update --init --recursive
```

#### B.3. Sign in with the jumpbox managed identity

The `.azure/<env>/.env` already came over with the bootstrap — no refresh needed.
Just log `az` in with the VM's MI:

```powershell
az login --identity
```

> **Fallback** (only if `az login --identity` fails):
> ```powershell
> az login --use-device-code --tenant <AZURE_TENANT_ID>
> ```

#### B.4. Run the post-provision hook from inside the VNet

```powershell
pwsh -NoProfile -File .\scripts\postProvision.ps1
# When prompted: "Are you running this script from inside the VNet or via VPN? [Y/n]"
# → answer "Y"
```

Expected output:

```text
[OK] AZURE_CONTAINER_REGISTRY_ENDPOINT set to 'cr<token>.azurecr.io'.
[OK] Container App '<...>' bound to ACR via system-assigned identity.
[OK] App Configuration updated (AZURE_INPUT_TRANSCRIPTION_MODEL=azure-speech).
[>] Running Search data-plane setup hook ... (skillset/index/indexer created)
[>] Running Cosmos sample seed hook ... (scenarios + rubrics upserted)
[OK] post-provision hook completed.
```

If `Resolve-DnsName appcs-<token>.azconfig.io` does **not** return a `192.168.*` private IP, the private DNS zone link is missing or the resolver cache is stale — restart the VM and retry.

#### B.5. Build & deploy the container image from the jumpbox

The jumpbox does **not** have Docker installed (by design). Image builds use the ACR Tasks agent pool inside the VNet:

```powershell
azd deploy
```

`azd deploy` will:

1. Read `AZURE_CONTAINER_REGISTRY_ENDPOINT`, `AZURE_RESOURCE_GROUP`, `AZURE_CONTAINER_APP_NAME` from App Configuration / azd env.
2. Run `az acr build --agent-pool build-pool` to build the image inside the VNet and push it to the private ACR.
3. Update the `voicelab` Container App to the new image and restart the latest revision.

If you prefer to drive the build manually:

```powershell
$rg  = azd env get-value AZURE_RESOURCE_GROUP
$acr = az acr list -g $rg --query "[0].name" -o tsv
$tag = (git rev-parse --short HEAD)
az acr build -r $acr --agent-pool build-pool --image voicelab:$tag --image voicelab:latest .
$ca = az containerapp list -g $rg --query "[0].name" -o tsv
az containerapp update -g $rg -n $ca --image "$acr.azurecr.io/voicelab:$tag"
```

#### B.6. Validate from the jumpbox

```powershell
$rg  = azd env get-value AZURE_RESOURCE_GROUP
$ca  = az containerapp list -g $rg --query "[0].name" -o tsv
$fqdn = az containerapp show -g $rg -n $ca --query "properties.configuration.ingress.fqdn" -o tsv
"https://$fqdn"
```

Open that URL in the jumpbox browser (Edge is preinstalled). The ingress is internal-only in NI mode, so it resolves through `privatelink.<region>.azurecontainerapps.io` from inside the VNet without needing the Application Gateway yet.

If something looks off, tail the container logs:

```powershell
az containerapp logs show -g $rg -n $ca --follow --tail 100
```

#### B.7. (Optional) Expose the app publicly with a real domain

This step is **only needed if you want a public Internet entry point** for the app — typically to let testers reach it from a real workstation with a real microphone. If you only need to reach the app from the jumpbox / Bastion, an Azure Virtual Desktop in the spoke, or an ExpressRoute/VPN into the VNet, skip this section: the Application Gateway is not deployed by default and no further action is required.

To opt in, set `azd env set PUBLIC_INGRESS_ENABLED true` and re-run `azd provision`, then follow the [public ingress runbook](manual-testing/public-ingress-runbook.md). It walks through the BYO domain + Key Vault certificate step that wires the Application Gateway WAF v2 to your domain, and configures the NSG allow-list with the source IPs you want to grant access to.

#### B.8. Shut down the jumpbox when you're done

To save cost, deallocate the VM after each session (the disk persists, OS state is preserved for next time):

```powershell
$rg = azd env get-value AZURE_RESOURCE_GROUP
az vm deallocate -g $rg -n testvm<token> --no-wait
```

> [!] **Don't deallocate the VM mid-`azd provision`.** The Bicep template applies VM extensions (`cse`, `MDE.Windows`, `MicrosoftAntiMalware`) on every provision and Azure rejects extension changes when the VM is stopped (`OperationNotAllowed: Cannot modify extensions in the VM when the VM is not running`). Always **start** the VM before re-running `azd provision`/`azd up`.

---

## Iterating in NI mode

| Change | Where to run | Command |
|--------|--------------|---------|
| App code (backend / frontend) | Jumpbox | `azd deploy` |
| Bicep / infra parameters | Workstation, then jumpbox to re-run hook | `azd provision`, then `pwsh ./scripts/postProvision.ps1` on jumpbox if data-plane drift |
| New AI Search index field | Jumpbox | `pwsh ./scripts/setup_search_dataplane.ps1` |
| New Cosmos sample data | Jumpbox | `python scripts/seed_cosmos_samples.py --mode upsert` |

---

## Teardown

From your workstation:

```powershell
azd down --force
# add --purge to also purge soft-deleted Cognitive Services / Key Vault accounts (slow)
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `OperationNotAllowed: Cannot modify extensions in the VM when the VM is not running` during `azd provision` | The jumpbox VM is deallocated. Run `az vm start -g <rg> -n testvm<token>` and re-run `azd provision`. |
| `403 ip-address-rejected` from `az appconfig kv set` | You're outside the VNet. Re-run `postProvision.ps1` from the jumpbox. |
| `azd env refresh` fails with `Failed: Downloading Bicep` from the jumpbox | The firewall is missing `downloads.bicep.azure.com` in the bootstrap allow-list. Fixed in AILZ submodule **v1.1.4+**. Verify `git -C infra describe --tags`. |
| `Resolve-DnsName <acr>.azurecr.io` returns a public IP from the jumpbox | The DNS zone link on `privatelink.azurecr.io` is missing or stale. Restart the VM to flush its DNS cache. |
| Container App revision stuck in `Provisioning` | Check `az containerapp logs show ... --type system`. Most failures are missing `AcrPull` on the Container App's managed identity (Bicep should grant it; verify with `az role assignment list --assignee <ca-mi-objectid>`). |
| Cosmos seed fails with `ResourceNotFound` | Cosmos PE may still be propagating; wait a minute and re-run `pwsh ./scripts/postProvision.ps1`. |
| Key Vault data-plane (`secret list`) returns `Forbidden` | Your principal needs `Key Vault Secrets User`/`Officer` on `kv-<token>`. Run `azd provision` once with your principalId set so Bicep grants the executor role. |

---

## Reference

- Architecture: [docs/how-it-works.md](how-it-works.md)
- AI Search dataplane: [docs/ai-search-indexing-runbook.md](ai-search-indexing-runbook.md)
- NI quick reference (subnets, FQDNs, firewall rules): [docs/network-isolation-jumpbox-runbook.md](network-isolation-jumpbox-runbook.md)
- Scripts: [scripts/postProvision.ps1](../scripts/postProvision.ps1) · [scripts/setup_search_dataplane.ps1](../scripts/setup_search_dataplane.ps1) · [scripts/seed_cosmos_samples.py](../scripts/seed_cosmos_samples.py)
- AILZ submodule: [`infra/`](../infra/) (pin: `v2.0.14`)
