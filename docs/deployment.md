# Deployment Guide

This guide explains how to deploy **Live Voice Practice** to Azure in two modes:

1. **Basic deployment** — public endpoints, no Azure Firewall / Bastion / jumpbox. Fastest path; suitable for development, demos, and personal sandboxes.
2. **Network-isolated (Zero Trust) deployment** — private endpoints, Azure Firewall egress control, all data-plane traffic stays inside the VNet. Required for production-grade environments.

Both modes share the same Azure Developer CLI (`azd`) workflow:

```
azd auth login
azd env new <env-name>
# (set NETWORK_ISOLATION=true for the isolated mode — see below)
azd up                      # first time only (provision + deploy)
# subsequent iterations:
azd deploy                  # app code changes
azd provision               # infra/Bicep changes
```

`azd up` ≡ `azd provision` followed by `azd deploy`. The `postprovision` hook (`scripts/postProvision.ps1` / `scripts/postProvision.sh`) runs automatically at the end of `azd provision`.

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

---

## Mode 1 — Basic deployment

### 1. Create the azd environment

```powershell
azd env new <env-name>
azd env set AZURE_LOCATION       <region>             # e.g. swedencentral
azd env set AZURE_SUBSCRIPTION_ID <subscription-guid>
azd env set NETWORK_ISOLATION    false                # default
# optional: pin Azure AI Search to another region
azd env set AZURE_SEARCH_LOCATION northeurope
```

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

> **Authentication: Entra ID only (no keys).** This solution does not use any account / admin / connection-string keys. Every component authenticates via Microsoft Entra ID:
> - The Container App's system-assigned managed identity calls AI Foundry, Speech, Cosmos DB, AI Search, Key Vault, App Configuration and Storage with `DefaultAzureCredential`.
> - The AI Search service's system-assigned managed identity is used by indexers/skillsets to read from Storage and call AI Foundry embeddings (datasource connection string uses the `ResourceId=...` form, no `AccountKey`).
> - `scripts/setup_search_dataplane.{ps1,sh}` and `scripts/seed_cosmos_samples.py` use `az rest --resource https://search.azure.com`, `az storage --auth-mode login` and `DefaultAzureCredential` respectively.
>
> **Required RBAC for the principal running `postprovision` (jumpbox MI in Mode 2, your dev user in Mode 1):**
> - Storage account: `Storage Blob Data Contributor`
> - AI Search: `Search Service Contributor` + `Search Index Data Contributor`
> - AI Foundry / Speech: `Cognitive Services Contributor` (or `Cognitive Services OpenAI User` + `Cognitive Services User`)
> - App Configuration: `App Configuration Data Owner`
> - Key Vault: `Key Vault Secrets Officer` (or `Key Vault Secrets User` for read-only flows)
> - Cosmos DB: `Cosmos DB Built-in Data Contributor` (data-plane, assigned via `az cosmosdb sql role assignment create`)
> - Permission to create role assignments on the Storage account and AI Foundry account (so the script can grant the Search MI access to them); if not available, run `az role assignment create` once manually with an Owner-level account.

The deployment is split into two phases:

- **Phase A — workstation:** `azd provision` creates infra. The `postprovision` hook runs but **skips** all data-plane steps because they cannot reach private endpoints from your laptop.
- **Phase B — jumpbox:** you connect to the in-VNet jumpbox via Bastion, clone the repo, and re-run the `postprovision` hook (which now can reach the private endpoints), then run `azd deploy` (which uses the ACR Tasks agent pool to build the image inside the VNet).

### Phase A — Provision from your workstation

#### A.1. Create the azd environment

```powershell
azd env new <env-name>
azd env set AZURE_LOCATION                       <region>            # e.g. swedencentral
azd env set AZURE_SUBSCRIPTION_ID                <subscription-guid>
azd env set NETWORK_ISOLATION                    true
azd env set AZURE_SKIP_NETWORK_ISOLATION_WARNING true
azd env set AZURE_SEARCH_LOCATION                northeurope         # optional
azd env set DEPLOY_SPEECH_SERVICE                true                # default true
```

> The Bastion + Azure Firewall + jumpbox VM are part of the Bicep template (`deployVM=true`, default). The firewall policy is pre-configured with the FQDN allow-list needed to bootstrap the jumpbox (`azd`, Bicep CLI, GitHub, Speech, Foundry, ACR, …).

#### A.2. Run provision

```powershell
azd provision
```

Expected console output:

```text
SUCCESS: Your application was provisioned in Azure in <NN> minutes ...
🔧 Running post-provision hook...
🔒 Zero Trust / Network Isolation enabled.
   ❓ Are you running this script from inside the VNet or via VPN? [Y/n]
```

Answer **`n`** (or just leave it for the non-interactive azd hook — the hook auto-skips when stdin is redirected). The hook will report:

```text
ℹ️  Network isolation is enabled. Three data-plane steps were skipped:
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
# verify the submodule landed on the expected pin (v1.1.4 = 40f82ae or newer)
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
✅ AZURE_CONTAINER_REGISTRY_ENDPOINT set to 'cr<token>.azurecr.io'.
✅ Container App '<...>' bound to ACR via system-assigned identity.
✅ App Configuration updated (AZURE_INPUT_TRANSCRIPTION_MODEL=azure-speech).
🔎 Running Search data-plane setup hook ... (skillset/index/indexer created)
🌱 Running Cosmos sample seed hook ... (scenarios + rubrics upserted)
✅ post-provision hook completed.
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
$rg = azd env get-value AZURE_RESOURCE_GROUP
$ca = az containerapp list -g $rg --query "[0].name" -o tsv

az containerapp show -g $rg -n $ca `
  --query "{fqdn:properties.configuration.ingress.fqdn,revision:properties.latestRevisionName,running:properties.runningStatus}" -o table

az containerapp logs show -g $rg -n $ca --follow --tail 100
```

Open the FQDN in a browser **inside the jumpbox** — in NI mode the ingress is internal-only (resolves through `privatelink.<region>.azurecontainerapps.io`).

#### B.7. Shut down the jumpbox when you're done

To save cost, deallocate the VM after each session (the disk persists, OS state is preserved for next time):

```powershell
$rg = azd env get-value AZURE_RESOURCE_GROUP
az vm deallocate -g $rg -n testvm<token> --no-wait
```

> ⚠️ **Don't deallocate the VM mid-`azd provision`.** The Bicep template applies VM extensions (`cse`, `MDE.Windows`, `MicrosoftAntiMalware`) on every provision and Azure rejects extension changes when the VM is stopped (`OperationNotAllowed: Cannot modify extensions in the VM when the VM is not running`). Always **start** the VM before re-running `azd provision`/`azd up`.

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
- Scripts: [scripts/postProvision.ps1](../scripts/postProvision.ps1) · [scripts/setup_search_dataplane.ps1](../scripts/setup_search_dataplane.ps1) · [scripts/seed_cosmos_samples.py](../scripts/seed_cosmos_samples.py) · [scripts/add-jumpbox-fw-rules.ps1](../scripts/add-jumpbox-fw-rules.ps1)
- AILZ submodule: [`infra/`](../infra/) (pin: `v1.1.4` — first-class Speech support, Bicep CLI bootstrap FQDN)
