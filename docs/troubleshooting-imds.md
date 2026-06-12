# Troubleshooting: Container Apps IMDS / Managed Identity Failures

## Symptom

You deploy the app, the deployment "succeeds" without errors, but:

- Frontend's scenario picker is empty
- `GET /api/scenarios` returns `503` with body
  `{"code": "COSMOS_AUTH_FAILED", ...}`
- `GET /api/health` returns `503` with `checks.scenarios.status =
  "degraded_auth_failure"`
- Container App logs contain one of:
  - `(invalid_scope) 500 Internal Server Error` against
    `http://localhost:<port>/msi/token`
  - `ManagedIdentityCredential` / `DefaultAzureCredential failed`
  - `CredentialUnavailableError`

This means the **Container Apps IMDS sidecar** (the localhost token
endpoint that the SDK calls to mint a managed-identity token) is
returning errors for every token request. It is a platform-level bug,
not something in your app, infra, or RBAC.

## Quick confirmation (1 line)

If you have a jumpbox VM in the VNet, you can confirm it's IMDS and
not RBAC with one command. Replace `<rg>`, `<vm>`, `<fqdn>` accordingly:

```powershell
az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts "curl -fsS https://<fqdn>/api/health" --query 'value[0].message' -o tsv
```

If `status = degraded_auth_failure` and `last_error` mentions IMDS or
`invalid_scope`, you have the IMDS bug. If RBAC were the issue you'd
see `Forbidden` / `403` in `last_error` instead.

## Remediation paths (try in order)

### 1. Use User-Assigned Identity (`USE_UAI=true`) — **recommended**

The root cause was upstream issue
[Azure/bicep-ptn-aiml-landing-zone#38](https://github.com/Azure/bicep-ptn-aiml-landing-zone/issues/38)
(closed 2026-04-30): the Container App template emitted
`AZURE_CLIENT_ID=""` (empty string) when SystemAssigned MI was used. An
empty `AZURE_CLIENT_ID` confused `DefaultAzureCredential` →
`EnvironmentCredential` failed → `ManagedIdentityCredential` queried IMDS
with the empty client_id → `HTTP 500 invalid_scope`.

The landing zone already supports **User-Assigned Managed Identity** as a
first-class deployment mode. With UAI on, the bicep populates
`AZURE_CLIENT_ID` with a real client ID and `DefaultAzureCredential`
routes cleanly to `ManagedIdentityCredential` for that specific UAI,
bypassing the broken empty-scope codepath.

Enable it before provisioning a fresh environment:

```bash
azd env set USE_UAI true
azd env set NETWORK_ISOLATION true   # optional, for zero-trust topology
azd provision
```

This requires no Entra app-registration permission, no client-secret
rotation, no master keys, and no submodule edits.

### 2. Restart the active revision

Sometimes the IMDS sidecar recovers after a restart, even with
SystemAssigned MI. Worth trying once before re-provisioning.

```powershell
$rev = az containerapp revision list -g <rg> -n <app> --query '[?properties.active].name | [0]' -o tsv
az containerapp revision restart -g <rg> -n <app> --revision $rev
# Wait 30s, then re-test:
curl -fsS https://<fqdn>/api/health
```

### 3. Re-provision with `USE_UAI=true`

If you're already on an environment provisioned with SystemAssigned MI
and step 2 doesn't help, the cleanest fix is to recreate with UAI:

```bash
azd env set USE_UAI true
azd down --purge --force   # or `az group delete`
azd provision
azd deploy
```

### 4. Service Principal workaround (legacy, requires Entra permission)

> **Note:** This path is preserved for environments that **cannot**
> enable `USE_UAI=true` (e.g., infra is not the AILZ pattern). Most
> users should not need this. Scripts moved to `scripts/legacy/`.

If `USE_UAI=true` is not an option, you can fall back to a Service
Principal injected as environment credential. `DefaultAzureCredential`
uses `EnvironmentCredential` *before* `ManagedIdentityCredential`, so
this bypasses IMDS entirely.

```powershell
./scripts/legacy/imds-workaround.ps1
```

**Permission required:** ability to register applications in your
Entra tenant. Roles that satisfy this:

- **Application Developer** (least privilege)
- **Application Administrator**
- **Cloud Application Administrator**
- **Global Administrator**

If you don't have any of these, prefer step 1 (`USE_UAI=true`) which
needs no Entra permissions.

To remove the workaround later:

```powershell
./scripts/legacy/imds-workaround-remove.ps1
```

### 5. Open a Microsoft support ticket

If you've enabled `USE_UAI=true` and *still* see IMDS failures, that
would be a different platform bug. Open a ticket against **Azure
Container Apps**. Collect:

- `subscriptionId`, `resourceGroup`, Container App name
- The Container App **revision name** (each revision has a separate
  IMDS sidecar)
- Resource ID of the Container Apps **environment**
- Sample `invocationId` from the failing token request (visible in
  Container App console logs)
- Time window of the failures (UTC)

## How the workaround works under the hood

```
┌────────────────────────────────────────────────────────────┐
│ Container App                                              │
│                                                            │
│  Python SDK → DefaultAzureCredential                       │
│      │                                                     │
│      ├── 1. EnvironmentCredential                          │
│      │     reads AZURE_CLIENT_ID / TENANT_ID / SECRET      │
│      │     hits AAD directly (login.microsoftonline.com)   │ ← workaround
│      │     ✔ token returned                                │
│      │                                                     │
│      ├── 2. ManagedIdentityCredential                      │
│      │     hits localhost IMDS sidecar                     │
│      │     ✘ returns invalid_scope / 500                   │ ← broken
│      │                                                     │
│      └── ...                                               │
└────────────────────────────────────────────────────────────┘
```

When the env vars are set, `EnvironmentCredential` succeeds first and
the SDK never tries IMDS. The Service Principal carries the same
data-plane RBAC as the SystemAssigned MI (Cosmos DB Built-in Data
Contributor, App Configuration Data Reader, etc.).

## Why we don't enable the workaround by default

- It requires creating a Service Principal in your Entra tenant.
  Many enterprise environments restrict this to a small group of
  admins, so making it default would break those deployments.
- A SystemAssigned MI is more secure (no shared secret, automatic
  rotation, scoped to the resource lifecycle). The platform bug
  affects only some environments / time windows, not all deployments.
- We want to *detect* the failure cleanly (postDeploy smoke test,
  `/api/health`) rather than mask it.

## Auto-detection

The post-deploy hook (`scripts/postDeploy.*`) hits `/api/health` after
every `azd deploy` and **fails the deploy** if it sees
`degraded_auth_failure`. This means:

- You see the problem within 1-2 minutes of the deploy completing
- The failure points at this document
- You don't ship a "successful" deploy where the frontend silently
  shows an empty list
