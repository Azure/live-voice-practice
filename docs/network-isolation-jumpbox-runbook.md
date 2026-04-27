# Network Isolation — Jumpbox runbook

When `NETWORK_ISOLATION=true`, most data-plane endpoints (ACR, App Configuration,
AI Search, Cosmos DB, Key Vault, Speech, Foundry) reject traffic from the public
internet. The `azd provision` hook runs from your workstation and is expected to
log warnings such as:

- `⏭️ NETWORK_ISOLATION=true: skipping Search data-plane setup (...)`
- `⏭️ NETWORK_ISOLATION=true: skipping Cosmos sample seed (...)`
- `⚠️ App Configuration data-plane not reachable from current network (NI mode).`

These steps, plus the container image build/push and `azd deploy`, must be
completed from the **jumpbox VM** inside the spoke VNet. Connect to it via
**Azure Bastion** and follow the steps below.

---

## 0. Prerequisites (on your workstation)

Run `azd provision` once from your workstation so the infrastructure
(including ACR, jumpbox VM, Bastion, private endpoints, and Container App) is
created. A `SUCCESS: Your application was provisioned in Azure` message means
the control plane is complete — the jumpbox steps pick up from there.

Capture these values (from `azd env get-values` or the Azure Portal) — you will
re-enter them inside the VM:

| Variable | Example |
|----------|---------|
| `AZURE_SUBSCRIPTION_ID` | `9788a92c-2f71-4629-8173-7ad449cb50e1` |
| `AZURE_TENANT_ID` | `16b3c013-d300-468d-ac64-7eda0820b6d3` |
| `AZURE_RESOURCE_GROUP` | `rg-voice-live-ni-<timestamp>` |
| `AZURE_ENV_NAME` | `voice-live-ni-<timestamp>` |
| `AZURE_LOCATION` | `eastus2` |
| `APP_CONFIG_ENDPOINT` | `https://appcs-<token>.azconfig.io` |
| `AZURE_CONTAINER_REGISTRY_ENDPOINT` | `cr<token>.azurecr.io` |
| `AZURE_CONTAINER_APP_NAME` | `ca-<token>-voicelab` |
| VM name | `testvm<token>` (8-char suffix from the resource token) |

---

## 1. Connect to the jumpbox via Bastion

1. In the Azure Portal, open the resource group
   (`rg-voice-live-ni-<timestamp>`).
2. Select the VM named `testvm<token>`.
3. Click **Connect → Bastion**.
4. Provide the admin credentials configured during provisioning
   (`vmAdminUsername` / `vmAdminPassword` parameters).
5. Enable the clipboard (paste button on the Bastion toolbar) so you can copy
   commands into the RDP session.

> The jumpbox is a Windows Server VM on the `jumpbox-subnet`. It is the only
> host that can reach the private endpoints of ACR, App Config, Search, Cosmos,
> and Key Vault through the linked private DNS zones.

---

## 2. Install tooling inside the VM (first time only)

Open an elevated **PowerShell** terminal on the jumpbox and install:

```powershell
# Azure CLI
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
Remove-Item .\AzureCLI.msi

# Azure Developer CLI (azd)
powershell -ex AllSigned -c "Invoke-RestMethod 'https://aka.ms/install-azd.ps1' | Invoke-Expression"

# Git, Python 3.11+, Node.js LTS (only needed if you will build the frontend here)
winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements
winget install --id Python.Python.3.11 -e --accept-source-agreements --accept-package-agreements

# Docker Desktop (required for image build/push via buildx)
winget install --id Docker.DockerDesktop -e --accept-source-agreements --accept-package-agreements
```

Sign out / sign back in (or reboot) after Docker Desktop installs, then start
Docker Desktop and wait for the whale icon to turn ready.

Verify:

```powershell
az --version
azd version
docker version
docker buildx version
```

---

## 3. Sign in

```powershell
# Azure CLI — use device code if the VM blocks interactive browser
az login --tenant <AZURE_TENANT_ID> --use-device-code
az account set --subscription <AZURE_SUBSCRIPTION_ID>

# azd
azd auth login --tenant-id <AZURE_TENANT_ID>
```

---

## 4. Get the repository and select the azd environment

```powershell
cd $HOME
git clone https://github.com/<your-org>/live-voice-practice.git
cd live-voice-practice

azd env select <AZURE_ENV_NAME>
# Verify you see the same RG/subscription:
azd env get-values | Select-String -Pattern 'AZURE_RESOURCE_GROUP|AZURE_SUBSCRIPTION_ID|APP_CONFIG_ENDPOINT'
```

If the env does not exist on this machine, create it and copy the values:

```powershell
azd env new <AZURE_ENV_NAME> --subscription <AZURE_SUBSCRIPTION_ID> --location <AZURE_LOCATION>
azd env set NETWORK_ISOLATION true
azd env set AZURE_RESOURCE_GROUP <AZURE_RESOURCE_GROUP>
azd env set APP_CONFIG_ENDPOINT <APP_CONFIG_ENDPOINT>
azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT <ACR_LOGIN_SERVER>
azd env set AZURE_CONTAINER_APP_NAME <AZURE_CONTAINER_APP_NAME>
```

---

## 5. Re-run the post-provision hook from inside the VNet

The hook is idempotent. Running it from the jumpbox lets the data-plane steps
(App Configuration writes, Search indexing, Cosmos seed) succeed:

```powershell
pwsh -NoProfile -File .\scripts\postProvision.ps1
```

Expected output:

- `✅ Speech private endpoint and DNS configured.` (already done, no-op)
- `✅ Role assignment ensured for container app ...`
- `✅ App Configuration updated.`
- Search data-plane setup runs and indexes are created.
- Cosmos sample seed runs (`seed_cosmos_samples.py`).

If App Configuration still returns `403 ip-address-rejected`, confirm that the
jumpbox NIC IP is on the `jumpbox-subnet` and that the private DNS zone
`privatelink.azconfig.io` resolves `appcs-<token>.azconfig.io` to a
`10.*/192.168.*` address:

```powershell
Resolve-DnsName appcs-<token>.azconfig.io
```

---

## 6. Build and push the container image to the private ACR

From the repo root on the jumpbox:

```powershell
pwsh -NoProfile -File .\scripts\deploy.ps1
```

`deploy.ps1` will:

1. Detect `NETWORK_ISOLATION=true` and continue (it only aborts when run
   outside the VNet).
2. Verify Docker + buildx.
3. Read `CONTAINER_REGISTRY_NAME`, `CONTAINER_REGISTRY_LOGIN_SERVER`,
   `AZURE_RESOURCE_GROUP`, and `VOICELAB_APP_NAME` from App Configuration.
4. `az acr login` against the private ACR (resolves via private endpoint).
5. `docker buildx build --platform linux/amd64 --push` with a tag of
   `<git-sha>` (or timestamp when the tree is dirty) plus `:latest`.
6. `az containerapp update` to point the `ca-<token>-voicelab` Container App
   at the new image and restart the latest revision.

Alternative: `azd deploy` — this calls the same predeploy hook and works from
the jumpbox as long as Docker Desktop is running.

---

## 7. Validate the deployment

Still on the jumpbox:

```powershell
# Container App provisioning + running revision
az containerapp show -g <AZURE_RESOURCE_GROUP> -n <AZURE_CONTAINER_APP_NAME> `
  --query "{fqdn:properties.configuration.ingress.fqdn,revision:properties.latestRevisionName,status:properties.runningStatus}" -o table

# Latest revision health
az containerapp revision list -g <AZURE_RESOURCE_GROUP> -n <AZURE_CONTAINER_APP_NAME> `
  --query "[0].{name:name,active:properties.active,healthState:properties.healthState,replicas:properties.replicas}" -o table

# Tail logs (container stdout)
az containerapp logs show -g <AZURE_RESOURCE_GROUP> -n <AZURE_CONTAINER_APP_NAME> --follow --tail 100
```

Open the app FQDN from a browser **inside the jumpbox** (the Container App
ingress is internal-only in NI mode).

---

## 8. Optional — run smoke tests

```powershell
# Backend tests against the deployed API (from the jumpbox, so private DNS resolves)
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt -r requirements-test.txt
pytest tests\integration -k "network_isolation" -q
```

---

## 9. Shut down / clean up

- Sign out of Bastion (or close the browser tab) to release the session.
- Stop the VM from the portal to avoid compute charges:
  `az vm deallocate -g <AZURE_RESOURCE_GROUP> -n testvm<token>`.
- Full teardown: `azd down --force --purge` from your workstation.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `az appconfig kv set ... 403 ip-address-rejected` | You are running from outside the VNet. Re-run from the jumpbox. |
| `docker: error during connect: ... pipe/docker_engine` | Start Docker Desktop and wait for ready state. |
| `az acr login` hangs or fails TLS | `Resolve-DnsName <acr>.azurecr.io` must return a private IP. If not, verify the DNS zone link on `privatelink.azurecr.io` and restart the VM to flush the resolver cache. |
| `AccountCustomSubDomainNameNotSet` on Speech | `postProvision.ps1` now patches `customSubDomainName` automatically. If it already existed without the property, delete and purge the Speech account, then re-run the hook. |
| Cosmos seed script `ResourceNotFound` | Private endpoint for Cosmos may still be propagating. Wait a minute and re-run `scripts\postProvision.ps1`. |
| Container App revision stuck in `Provisioning` | Check ACR image pull: `az containerapp logs show ... --type system`. Most failures are the identity missing `AcrPull` on the registry. |

---

## Reference

- Jumpbox subnet: `jumpbox-subnet` (default `192.168.3.64/27`)
- Bastion subnet: `AzureBastionSubnet` (default `192.168.2.64/26`)
- Private endpoint subnet: `pe-subnet`
- Data-plane operations that require the VNet: ACR push/pull, App Configuration
  read/write, AI Search data-plane (`setup_search_dataplane.ps1`), Cosmos seed,
  Key Vault secret reads, Speech REST calls.
- Scripts referenced: [scripts/postProvision.ps1](../scripts/postProvision.ps1),
  [scripts/deploy.ps1](../scripts/deploy.ps1),
  [scripts/setup_search_dataplane.ps1](../scripts/setup_search_dataplane.ps1),
  [scripts/seed_cosmos_samples.py](../scripts/seed_cosmos_samples.py).
