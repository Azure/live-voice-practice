# Legacy: SP-based IMDS workaround

These scripts implemented a Service-Principal-based workaround for the
Container Apps managed-identity (IMDS) bug previously tracked as
`Azure/bicep-ptn-aiml-landing-zone#38` ("empty `AZURE_CLIENT_ID` env var
breaks DefaultAzureCredential on Container Apps with SystemAssigned
identity").

## Why they're quarantined

The bug had two paths to fix:

1. **Upstream**: emit `AZURE_CLIENT_ID` only when a User-Assigned Identity is
   configured. Filed and merged upstream — issue #38 closed 2026-04-30.
2. **Consumer-side**: use the landing zone's existing `useUAI=true` parameter,
   which assigns a per-app User-Assigned Identity and sets `AZURE_CLIENT_ID`
   to a real value. This is the recommended path.

`USE_UAI=true` requires no Entra app-registration permissions (managed
identities are ARM resources), no client-secret rotation, and no master keys.

## Migration

```bash
azd env set USE_UAI true
azd provision
```

If you still need an SP-based workaround (e.g., for a non-AILZ environment),
the scripts here are preserved as-is:

- `imds-workaround.ps1` — applies the SP workaround
- `imds-workaround-remove.ps1` — reverts it

See the script comments for usage. They require the running user to have
`Application Developer` (or higher) role in Entra to create app registrations.

## Don't use these unless

- You cannot enable `USE_UAI=true` (e.g., infra is not AILZ-based)
- AND you have Entra permissions to create app registrations
- AND you accept rotating client secrets
