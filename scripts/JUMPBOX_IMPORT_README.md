# Quick start: Import certificate from jumpbox

This is the fastest way to complete step 4 of the runbook without network access issues.

## Prerequisites

- `voicelab.pfx` transferred to the jumpbox (via Bastion file transfer or RDP copy)
- Jumpbox has managed identity with `Key Vault Certificates Officer` role ✓ (already configured)

## Steps

### 1. Connect to jumpbox via Bastion

In Azure Portal:
- Resource group: `rg-paulolacerda-0507261031`
- VM: `testvm7guer4i32`
- Click **Bastion** → Connect → Use file transfer to upload `voicelab.pfx`

### 2. Run the import script on jumpbox

Once connected to the jumpbox via RDP/SSH, open PowerShell and run:

```powershell
# Copy the PFX to a known location first (e.g., Desktop or Documents)
# Then navigate to that folder and run:

.\jumpbox-import-certificate.ps1
```

**Or** run it with custom values:

```powershell
.\jumpbox-import-certificate.ps1 `
  -KeyVaultName kv-7guer4i32clga `
  -CertificateName voicelab-cert `
  -PfxPassword myP@ssw0rd123456 `
  -PfxPath C:\path\to\voicelab.pfx
```

### 3. Save the output

The script will print the **Secret URI** at the end. Copy it (looks like `https://kv-xxxx.vault.azure.net/secrets/voicelab-cert`). You'll need this for step 5 of the runbook.

## Troubleshooting

**"PFX file not found"**
- Check that `voicelab.pfx` is in the current directory or specify `-PfxPath` with full path

**"Cannot reach Key Vault"**
- Jumpbox may not have network access to Key Vault (firewall issue)
- Contact your network team to allow egress to `vault.azure.net`

**"Access denied" or "Forbidden"**
- Managed identity may not have the right role
- Run from your workstation:
  ```powershell
  $jumpboxMiId = az vm identity show -n testvm7guer4i32 -g rg-paulolacerda-0507261031 --query 'principalId' -o tsv
  az role assignment create --role 'Key Vault Certificates Officer' --assignee-object-id $jumpboxMiId --scope /subscriptions/4c7ae2e2-8d3e-4712-9b7d-04ccbdcc7e70/resourceGroups/rg-paulolacerda-0507261031/providers/Microsoft.KeyVault/vaults/kv-7guer4i32clga --assignee-principal-type ServicePrincipal
  ```
- Wait 30 seconds for role propagation and retry
