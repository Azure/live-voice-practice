# Public ingress runbook — domain + certificate completion

> **Scope.** This runbook covers the operator-completed configuration of the optional **Application Gateway WAF v2 public ingress** introduced upstream by [`Azure/bicep-ptn-aiml-landing-zone#49`](https://github.com/Azure/bicep-ptn-aiml-landing-zone/issues/49) and consumed by this accelerator from `infra/` ≥ `v1.1.6`.
>
> **Pre-requisites.** A successful `azd provision` run with `NETWORK_ISOLATION=true` (which now also enables `publicIngress` by default — see [`main.parameters.json`](../../main.parameters.json)). The deployment is in **skeleton mode**: the gateway, Public IP, WAF policy, and a deny-all NSG are provisioned, but the HTTPS listener has no certificate, no hostname, and the NSG does not yet allow any source.
>
> **Outcome of this runbook.** The gateway transitions from skeleton mode to **live mode**: an HTTPS listener served by your TLS certificate, an HTTP→HTTPS redirect, and an NSG that allows TCP/443 only from the operator-controlled CIDRs. The application is then reachable at `https://<your-hostname>/` from a real workstation, with a real microphone, in a secure context, from any allow-listed IP.
>
> **Architectural decisions referenced.**
> - [ADR-0001 — Application Gateway pattern for manual testing](../adr/0001-manual-testing-microphone-application-gateway.md)
> - [ADR-0002 — Bring your own domain and certificate](../adr/0002-bring-your-own-domain-and-certificate.md)

---

## What you are completing, and why each step exists

The upstream module ([infra/modules/networking/public-ingress.bicep](../../infra/modules/networking/public-ingress.bicep)) deliberately deploys the gateway in **skeleton mode** when either `frontendHostName` or `sslCertSecretId` is empty. Skeleton mode means: the gateway exists, the Public IP is allocated, the backend pool is wired to the Container App's internal FQDN, the WAF policy is attached — and **no human can reach it**. The HTTPS listener is absent (no cert), and the NSG `AllowHttpsFromAllowedSources` rule is absent (no allow-listed CIDRs). Port 80 is **never** opened from the Internet by the NSG.

Skeleton mode lets you provision the network plumbing (which is slow and expensive to change) once, then complete the security-relevant parts (cert + hostname + IP allow-list) in a separate, fast, reversible step. This runbook is that second step.

This runbook does **not** prescribe a domain registrar, a DNS provider, or a certification authority. The list of substitutions in [§ Variations](#variations) shows how the same flow works with different choices. The walkthrough below uses one concrete combination as an example.

---

## 0. Read the deployment outputs

After `azd provision` completes, capture the values the rest of the runbook depends on:

```powershell
cd C:\path\to\live-voice-practice
azd env get-values |
  Select-String -Pattern 'PUBLIC_INGRESS_|KEY_VAULT_NAME|AZURE_RESOURCE_GROUP'
```

You should see at least:

```text
AZURE_RESOURCE_GROUP="rg-<env>"
KEY_VAULT_NAME="kv-<token>"
PUBLIC_INGRESS_ENABLED="true"
PUBLIC_INGRESS_PUBLIC_IP="20.x.x.x"
PUBLIC_INGRESS_GATEWAY_RESOURCE_ID="/subscriptions/.../applicationGateways/agw-<token>"
PUBLIC_INGRESS_NSG_RESOURCE_ID="/subscriptions/.../networkSecurityGroups/nsg-agw-<token>"
PUBLIC_INGRESS_IDENTITY_PRINCIPAL_ID="<guid>"
PUBLIC_INGRESS_LIVE="false"
```

`PUBLIC_INGRESS_LIVE=false` confirms the deployment is in skeleton mode.

If `PUBLIC_INGRESS_PUBLIC_IP` is empty, the deployment did not enable the public ingress. Check that `NETWORK_ISOLATION=true` (or set `PUBLIC_INGRESS_ENABLED=true` explicitly) and re-run `azd provision`.

---

## 1. Choose and register a domain

Choose a hostname you will publish to your testers. The hostname must be resolvable from the public Internet so that DNS-01 ACME challenges and the testers' browsers can both reach it. A subdomain of a domain you already own is sufficient and is the cheapest option (no registration cost, just a DNS record).

If you do not have a domain, register one with any registrar that lets you publish A and TXT records on the resulting zone. Common options include the major registrars and DNS-as-a-service providers; Azure DNS is also an option if you prefer to keep DNS inside Azure.

**Constraints.** None imposed by this accelerator. The accelerator does not register, route, or validate the domain. See [ADR-0002](../adr/0002-bring-your-own-domain-and-certificate.md).

**Output of this step.** A hostname you control (call it `voicelab.example.com` for the rest of this runbook) and access to the DNS panel for the parent zone (`example.com`).

---

## 2. Create the public DNS A record

In the DNS panel of your chosen provider, create an A record pointing the chosen hostname at the gateway's public IP:

```text
Type:  A
Name:  voicelab          (or whatever subdomain you chose, relative to the zone)
Value: 20.x.x.x          (the PUBLIC_INGRESS_PUBLIC_IP from step 0)
TTL:   300               (5 minutes — short while you iterate; raise after you go live)
```

Validate from your workstation:

```powershell
Resolve-DnsName voicelab.example.com -Type A
# expected answer: 20.x.x.x with the TTL you configured
```

Or with `dig` if you have it on WSL/Linux:

```bash
dig +short voicelab.example.com
# expected answer: 20.x.x.x
```

DNS propagation for a fresh record is typically under 5 minutes in modern providers. If validation fails, give it a few more minutes and verify the record appears in the provider's panel.

---

## 3. Obtain a TLS certificate for the chosen hostname

Obtain a certificate from any certification authority your audience's browsers trust by default. The accelerator does not endorse one CA over another. Three illustrative paths are listed in [§ Variations](#variations); the walkthrough below uses **certbot in manual DNS-01 mode** because it has zero per-cert cost, runs from any environment, and produces standard PEM artifacts.

### 3.a. Install certbot (one-time)

Choose any of:

```powershell
# Option 1 — official Windows installer (https://dl.eff.org/certbot-beta-installer-win32.exe)
winget install Certbot.Certbot
# verify
certbot --version
```

```bash
# Option 2 — WSL or any Linux machine
sudo apt-get install certbot
```

```powershell
# Option 3 — Docker (no install needed)
docker run --rm -it `
  -v ${PWD}/letsencrypt:/etc/letsencrypt `
  certbot/certbot --version
```

### 3.b. Run the manual DNS-01 challenge

```powershell
certbot certonly `
  --manual `
  --preferred-challenges dns `
  --agree-tos `
  --email you@example.com `
  -d voicelab.example.com
```

Certbot will pause and print a TXT record name and value. Example:

```text
Please deploy a DNS TXT record under the name:
  _acme-challenge.voicelab.example.com

with the following value:
  abc123XYZdef456...

Press Enter to Continue
```

Open the same DNS panel from step 2 and add the TXT record exactly as printed. Wait until it propagates:

```powershell
Resolve-DnsName _acme-challenge.voicelab.example.com -Type TXT
# expected answer: the abc123XYZdef456... value
```

Press Enter in the certbot terminal. On success, certbot writes (location depends on your install):

```text
- /etc/letsencrypt/live/voicelab.example.com/fullchain.pem
- /etc/letsencrypt/live/voicelab.example.com/privkey.pem
```

On Windows the equivalent path is under `C:\Certbot\live\voicelab.example.com\`.

### 3.c. Convert to PFX (Application Gateway requires PFX)

Application Gateway and Key Vault consume the certificate in PKCS#12 (PFX) form. Convert from PEM:

```powershell
# pick any password; you will use it on the next step's import
$pfxPassword = 'temporary-pfx-password'

openssl pkcs12 -export `
  -out voicelab.pfx `
  -inkey C:\Certbot\live\voicelab.example.com\privkey.pem `
  -in   C:\Certbot\live\voicelab.example.com\fullchain.pem `
  -passout pass:$pfxPassword
```

You now have `voicelab.pfx` on disk.

---

## 4. Import the certificate into the deployment's Key Vault

Use the Key Vault provisioned by the landing zone (`KEY_VAULT_NAME` from step 0). The Application Gateway's user-assigned identity has already been granted `Key Vault Secrets User` on this vault by the upstream module ([infra/modules/networking/public-ingress.bicep](../../infra/modules/networking/public-ingress.bicep) lines around RBAC), so no extra role assignment is required.

```powershell
$kv          = (azd env get-value KEY_VAULT_NAME)
$certName    = 'voicelab-cert'
$pfxPassword = 'temporary-pfx-password'   # the one used in 3.c

az keyvault certificate import `
  --vault-name $kv `
  --name       $certName `
  --file       .\voicelab.pfx `
  --password   $pfxPassword
```

Capture the **versionless** secret URI for the next step:

```powershell
$secretId = "https://$kv.vault.azure.net/secrets/$certName"
Write-Host $secretId
# expected: https://kv-<token>.vault.azure.net/secrets/voicelab-cert
```

> **External Key Vault?** If you imported the cert into a Key Vault that is *not* the one provisioned by the landing zone, grant `Key Vault Secrets User` to the gateway's identity manually:
>
> ```powershell
> az role assignment create `
>   --role 'Key Vault Secrets User' `
>   --assignee $(azd env get-value PUBLIC_INGRESS_IDENTITY_PRINCIPAL_ID) `
>   --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<external-kv>
> ```

---

## 5. Promote the gateway to live mode (Bicep is the source of truth)

The upstream module models live mode and skeleton mode **explicitly in Bicep**, so the operator-completed configuration is **not** drift — re-running `azd provision` after this step will reconcile the configuration cleanly. Do not edit the Application Gateway from the portal beyond what this runbook describes; portal-side changes will be reverted by the next provision.

Set the three operator-controlled values via `azd env`:

```powershell
azd env set PUBLIC_INGRESS_FRONTEND_HOSTNAME   voicelab.example.com
azd env set PUBLIC_INGRESS_SSL_CERT_SECRET_ID  $secretId
```

For the IP allow-list (`allowedSourceAddressPrefixes`), this accelerator's [`main.parameters.json`](../../main.parameters.json) does not currently expose an env var because the value is a list. Set it directly in `main.parameters.json`:

```jsonc
"publicIngress": {
  "value": {
    "enabled": "${PUBLIC_INGRESS_ENABLED=${NETWORK_ISOLATION=false}}",
    "frontendHostName": "${PUBLIC_INGRESS_FRONTEND_HOSTNAME=}",
    "sslCertSecretId": "${PUBLIC_INGRESS_SSL_CERT_SECRET_ID=}",
    "allowedSourceAddressPrefixes": [
      "203.0.113.42/32",
      "198.51.100.0/24"
    ]
  }
}
```

Replace the example CIDRs with the public egress IPs of your testers. Use `/32` for a single workstation. To find a tester's egress IP they can visit `https://api.ipify.org` from their browser and read the response. Keep this list as small as possible.

Then re-provision:

```powershell
azd provision
```

The reconcile is fast (only the gateway listener, redirect rule, NSG rule, and the cert reference change). Validate the transition:

```powershell
azd env get-value PUBLIC_INGRESS_LIVE
# expected: true
```

---

## 6. Validate end-to-end

From a workstation whose egress IP is in the allow-list:

```powershell
# HTTPS reaches the app
curl -v https://voicelab.example.com/
# expected: 200 OK from the Container App, valid TLS chain

# HTTP redirects to HTTPS
curl -v http://voicelab.example.com/
# expected: 301 to https://voicelab.example.com/

# Browser test — open in Edge/Chrome on the same workstation
# expected: TLS green padlock, app loads, "Start Recording" exposes the
# real microphone (this is the whole point — secure context + real device).
```

From a workstation whose egress IP is **not** in the allow-list:

```powershell
curl -v --max-time 10 https://voicelab.example.com/
# expected: connection times out (NSG drop). This is the deny-by-default posture working.
```

---

## 7. Tear down when the testing window ends

The gateway and Public IP incur hourly charges (~USD 240/month for the gateway alone). When you no longer need the public ingress, tear it down. Two paths:

### 7.a. Tear down the entire deployment (recommended)

```powershell
azd down --force --purge
```

This removes the resource group, including the gateway, Public IP, WAF policy, NSG, Key Vault (purged), and everything else.

### 7.b. Tear down only the public ingress, keep the rest

```powershell
azd env set PUBLIC_INGRESS_ENABLED false
azd provision
```

> **Caveat documented upstream.** `azd`/ARM incremental deployments will **not** delete public-ingress resources when `publicIngress.enabled` flips back to `false` after a previous deploy. The upstream module documents this explicitly. To actually remove the resources without `azd down`, you must delete them manually:
>
> ```powershell
> $rg  = azd env get-value AZURE_RESOURCE_GROUP
> $agw = (azd env get-value PUBLIC_INGRESS_GATEWAY_RESOURCE_ID).Split('/')[-1]
> az network application-gateway delete -g $rg -n $agw
> # also delete the corresponding PIP, WAF policy, and NSG by reading their resource IDs from azd env
> ```

In either case, the application's internal posture (Container Apps environment with `internal=true`, private endpoints) is preserved across teardown and re-provision of the public ingress. You can flip the public ingress on and off without touching the workload.

---

## Variations

The walkthrough above uses one concrete toolchain. Each step has equivalent substitutions:

| Step | Walkthrough used | Equivalent alternatives |
|------|------------------|-------------------------|
| Domain | A registrar's DNS panel | Azure DNS zone (cheap if you already use Azure DNS); a corporate DNS zone if you control one. |
| Certificate | `certbot` manual DNS-01 + a publicly trusted free CA | `acme.sh` or `lego` from any environment; the certificate authority of your organization (skip ACME, generate a CSR, submit, receive, build PFX); a paid commercial CA with their portal-driven flow. |
| Cert format pipeline | `openssl pkcs12 -export` | `New-PfxCertificate` (Windows) when the source is already a Windows cert store entry; the CA's portal if it issues PFX directly. |
| Where the ACME client runs | Local PowerShell | Azure Cloud Shell, a CI runner, the jumpbox VM, a Linux laptop, a Docker container — any environment with outbound DNS and HTTP. |
| KV import | `az keyvault certificate import` | Portal: Key Vault → Certificates → Generate/Import → Import. |
| Listener config | `azd env set` + `azd provision` (Bicep is the source of truth) | **Do not** configure the listener directly in the portal — portal edits will be overwritten by the next `azd provision`. |
| IP allow-list | `main.parameters.json` `allowedSourceAddressPrefixes` array | Same — Bicep is the source of truth here too. Editing the NSG in the portal is portal drift. |

What does **not** vary across these substitutions:

- The Bicep contract (`publicIngress` parameter shape).
- The Key Vault secret reference handed to the gateway (`sslCertSecretId`, versionless URI).
- The output names (`PUBLIC_INGRESS_*`).
- The skeleton/live transition rule (live mode only when both `frontendHostName` and `sslCertSecretId` are set).

That stable contract is the point of [ADR-0002](../adr/0002-bring-your-own-domain-and-certificate.md).

---

## Renewals

Manual DNS-01 ACME challenges (the example in step 3) do not auto-renew. Most public CAs that issue via ACME issue 90-day certs. When a renewal is due:

1. Re-run step 3 with the same `-d voicelab.example.com`.
2. Re-run step 3.c to produce a fresh `voicelab.pfx`.
3. Re-run step 4 against the same `KEY_VAULT_NAME` and the same `voicelab-cert` name. The import creates a **new version**; the versionless `sslCertSecretId` automatically points at the latest version, so no Bicep change is required.
4. Restart the gateway listener so it picks up the new cert version:
   ```powershell
   az network application-gateway start `
     --name $(azd env get-value PUBLIC_INGRESS_GATEWAY_RESOURCE_ID).Split('/')[-1] `
     --resource-group $(azd env env get-value AZURE_RESOURCE_GROUP)
   ```
   In practice, AGW polls Key Vault every ~4 hours and rotates the cert without a restart; the explicit restart above only matters if you need the rotation immediately.

If you prefer hands-off renewals, swap the manual DNS-01 flow for an automated alternative (your registrar's API + an automation, or a managed ACME flow if available in your environment). The accelerator does not opine on this choice; the contract handed to the gateway (a versionless KV secret URI) is the same regardless of how the cert behind it was obtained.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `PUBLIC_INGRESS_ENABLED` is `false` after provision | `NETWORK_ISOLATION=false` or `PUBLIC_INGRESS_ENABLED=false`. | `azd env set NETWORK_ISOLATION true` or `azd env set PUBLIC_INGRESS_ENABLED true` and re-provision. |
| `PUBLIC_INGRESS_LIVE` stays `false` after step 5 | Either `frontendHostName` or `sslCertSecretId` is still empty on the gateway. | Re-check that both values were captured in `main.parameters.json` and that `azd provision` re-ran. `azd env get-values` should show non-empty values. |
| `curl https://voicelab.example.com/` returns `tls handshake timeout` from an allow-listed IP | DNS not propagated yet; or the allow-list does not include this IP. | Verify `Resolve-DnsName voicelab.example.com` returns the gateway IP, then check the NSG rule contains the IP's `/32`. |
| Browser shows certificate name mismatch | The cert was issued for a different hostname, or the listener was configured with a different hostname than the cert covers. | Re-issue the cert for the exact `frontendHostName`, or change `frontendHostName` to match. |
| Browser shows `NET::ERR_CERT_AUTHORITY_INVALID` | The CA root is not in this browser's trust store. | Use a publicly trusted CA, or import the corporate root CA on the tester's workstation. |
| `az keyvault certificate import` fails with `BadParameter: Could not parse` | The PFX is encrypted with an unsupported algorithm or the password is wrong. | Re-export the PFX with a known password and standard algorithms: `openssl pkcs12 -export -legacy -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg SHA256 ...` |
| `azd provision` fails with `KeyVault user is not authorized` on the gateway | The cert is in an external KV and the AGW UAI was not granted `Key Vault Secrets User` on it. | Run the role assignment from step 4 with the external KV's resource ID. |
| `curl https://voicelab.example.com/` returns `502 Bad Gateway` from an allow-listed IP | The backend pool resolved correctly but the Container App isn't responding on `/`, or the Container App's own ingress is misconfigured. | Verify with `azd env get-value VOICELAB_APP_FQDN` + a test from inside the VNet. The backend pool wiring itself is correct by construction (Bicep). |

---

## What this runbook is not

- It is not a hardening guide for the Application Gateway. The defaults (OWASP CRS 3.2 Prevention, deny-by-default NSG, TLS termination) are reasonable starting points, not a replacement for a security review of the workload exposure.
- It is not an identity layer. There is no Entra ID gating, no bearer-token check, no App Proxy. If you need authenticated access, layer that on top of the application or in front of the gateway.
- It is not a long-running production exposure pattern. It is a deployer-controlled, reversible, time-bounded entry point in front of an internally posted application. Production exposure has different drivers (custom domains as a feature, multi-region, identity-aware proxying, persistent WAF tuning) and should be its own decision.

---

## References

- [`infra/README.md` — Optional Public Ingress section](../../infra/README.md)
- [`infra/main.bicep` — `publicIngressType`](../../infra/main.bicep)
- [`main.parameters.json` — `publicIngress` parameter](../../main.parameters.json)
- [`docs/network-isolation-jumpbox-runbook.md`](../network-isolation-jumpbox-runbook.md) — Manual UI testing (microphone limitation) section
- [ADR-0001 — Application Gateway pattern for manual testing](../adr/0001-manual-testing-microphone-application-gateway.md)
- [ADR-0002 — Bring your own domain and certificate](../adr/0002-bring-your-own-domain-and-certificate.md)
- Upstream issue: [`Azure/bicep-ptn-aiml-landing-zone#49`](https://github.com/Azure/bicep-ptn-aiml-landing-zone/issues/49)
