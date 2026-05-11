# Public ingress runbook — domain + certificate completion

> **Scope.** This runbook completes the optional **Application Gateway WAF v2 public ingress** for a network-isolated deployment.
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

The infrastructure deliberately deploys the gateway in **skeleton mode** until both `frontendHostName` and `sslCertSecretId` are set. Skeleton mode means: the gateway exists, the Public IP is allocated, the backend pool is wired to the Container App's internal FQDN, the WAF policy is attached — and **no human can reach it**. The HTTPS listener is absent (no cert), and the NSG `AllowHttpsFromAllowedSources` rule is absent (no allow-listed CIDRs). Port 80 is **never** opened from the Internet by the NSG.

Skeleton mode lets you provision the network plumbing (which is slow and expensive to change) once, then complete the security-relevant parts (cert + hostname + IP allow-list) in a separate, fast, reversible step. This runbook is that second step.

This runbook does **not** prescribe a domain registrar, a DNS provider, or a certification authority. The list of substitutions in [§ Variations](#variations) shows how the same flow works with different choices. The walkthrough below uses one concrete combination as an example.

---

## 0. Read or carry forward the deployment outputs

This is a **management-plane lookup**. It can run from your workstation with your Azure user login, or from the jumpbox after logging the Azure CLI in with the jumpbox managed identity.

If you just ran `azd provision` from your workstation, keep the output values from that session and continue the rest of the runbook from the jumpbox. You do **not** need to leave the jumpbox for the certificate and Key Vault steps.

If you need to rediscover the values later from the jumpbox, log in first and then run the helper:

```powershell
az login --identity
cd C:\github\live-voice-practice
pwsh -File ./scripts/show-public-ingress-outputs.ps1
```

From your workstation, use your normal Azure user login instead:

```powershell
cd C:\path\to\live-voice-practice
pwsh -File ./scripts/show-public-ingress-outputs.ps1
```

The script prints one ready-to-copy PowerShell block. Keep the variables in your session because later steps use them:

```text
$rg     = 'rg-<env>'
$kv     = 'kv-<token>'
$ip     = '20.x.x.x'
$miPid  = '<guid>'
$gwId   = '/subscriptions/.../applicationGateways/agw-<token>'
$nsgId  = '/subscriptions/.../networkSecurityGroups/nsg-<token>'
$agw    = 'agw-<token>'
$publicIngressLive = $false
```

`$publicIngressLive = $false` confirms the deployment is in skeleton mode.

If the script reports that it cannot read Azure resources, first confirm Azure CLI login:

- **Jumpbox:** run `az login --identity`, then rerun the helper.
- **Workstation:** run `az login`, then rerun the helper.
- **Already logged in but still blocked:** continue using the output values from your `azd provision` session, or run the helper from the workstation where you provisioned the environment.

> **Why might this fail before `az login --identity`?** Azure CLI sessions are not automatically logged in just because the VM has a managed identity. The jumpbox has an identity available, but each shell still needs `az login --identity` before `az` can query Azure.

---

## Workflow overview: where each step runs

Because the Key Vault has **public network access disabled**, the workflow is split:

| Step | Location | Why |
|------|----------|-----|
| **0** (read/carry outputs) | Workstation or jumpbox after `az login --identity` | Requires Azure CLI login and ARM read access to deployment outputs/network resources |
| **1** (choose domain) | Your workstation | No Azure resources needed |
| **2** (create DNS A record) | Your workstation | Edit DNS provider UI |
| **3** (obtain TLS cert) | **Jumpbox recommended** | Run win-acme on the jumpbox; verify DNS propagation from your workstation or a public DNS checker |
| **4** (import to Key Vault) | **Jumpbox only** | Key Vault is not reachable from your workstation (public access disabled) |
| **5** (promote to live) | **Your workstation** | Run `azd env set`, edit `main.parameters.json`, and run `azd provision` |

**Bottom line:** Use the jumpbox for win-acme and Key Vault import. Use your workstation for DNS/provider checks and the final `azd env set` + `azd provision`. Do **not** use the jumpbox to test public DNS resolvers such as `8.8.8.8` or `1.1.1.1`; those queries can time out even when the public TXT record is correct.

---

## 1. Choose and register a domain

Choose a hostname you will publish to your testers. The hostname must be resolvable from the public Internet so that DNS-01 ACME challenges and the testers' browsers can both reach it. A subdomain of a domain you already own is sufficient and is the cheapest option (no registration cost, just a DNS record).

If you do not have a domain, register one with any registrar that lets you publish A and TXT records on the resulting zone. Common options include the major registrars and DNS-as-a-service providers; Azure DNS is also an option if you prefer to keep DNS inside Azure.

**Constraints.** None imposed by this accelerator. The accelerator does not register, route, or validate the domain. See [ADR-0002](../adr/0002-bring-your-own-domain-and-certificate.md).

**Output of this step.** A full public DNS hostname/FQDN you control, plus access to the DNS panel for its parent zone. In command examples below, set `$hostName` to that full hostname once and reuse it everywhere. For example, use `app.contoso.com`, not the short DNS provider host value `app`, and not the Container App's internal/default hostname. Do not copy example hostnames literally; replace them with your own public hostname.

---

## 2. Create the public DNS A record

In the DNS panel of your chosen provider, create an A record pointing the chosen hostname at the gateway's public IP:

```text
Type:  A
Name:  <your-subdomain>  (for app.contoso.com in the contoso.com zone, use app)
Value: 20.x.x.x          (the PUBLIC_INGRESS_PUBLIC_IP from step 0)
TTL:   300               (5 minutes — short while you iterate; raise after you go live)
```

Validate from your workstation:

```powershell
$hostName = '<your-hostname>'   # for example: app.contoso.com
Resolve-DnsName $hostName -Type A
# expected answer: 20.x.x.x with the TTL you configured
```

Or with `dig` if you have it on WSL/Linux:

```bash
dig +short <your-hostname>
# expected answer: 20.x.x.x
```

DNS propagation for a fresh record is typically under 5 minutes in modern providers. If validation fails, give it a few more minutes and verify the record appears in the provider's panel.

---

## 3. Obtain a TLS certificate for the chosen hostname

Obtain a certificate from any certification authority your audience's browsers trust by default. The accelerator does not endorse one CA over another. Three illustrative paths are listed in [§ Variations](#variations); the walkthrough below uses **win-acme** with Let's Encrypt and manual DNS-01 validation because it is a mature ACME client built specifically for Windows servers and does not require `winget`, WSL, Linux, or Docker.

### 3.a. Verify or install win-acme, then patch DNS pre-validation (one-time, Windows PowerShell)

win-acme is installed on the jumpbox by bootstrap. Verify first:

```powershell
$wacsDir = 'C:\tools\win-acme'
& "$wacsDir\wacs.exe" --version
```

If the command fails, install manually with:

```powershell
$wacsDir = 'C:\tools\win-acme'
$release = Invoke-RestMethod 'https://api.github.com/repos/win-acme/win-acme/releases/latest'
$asset = $release.assets |
  Where-Object { $_.name -like 'win-acme.*.x64.trimmed.zip' } |
  Select-Object -First 1

if (-not $asset) {
  throw 'Could not find the latest win-acme x64 trimmed release asset.'
}

$zip = Join-Path $env:TEMP $asset.name
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
New-Item -ItemType Directory -Path $wacsDir -Force | Out-Null
Expand-Archive -Path $zip -DestinationPath $wacsDir -Force

& "$wacsDir\wacs.exe" --version
```

If you are using the jumpbox, run the settings patch below **now**, even when `wacs.exe --version` worked and DNS already resolves. This is not another win-acme install. It only disables win-acme's local DNS pre-validation (`Validation.PreValidateDns=false`), which can fail in locked-down Windows environments before win-acme prints the DNS TXT value. Let's Encrypt still performs the authoritative DNS-01 validation, and you will still verify the TXT record with public DNS before continuing.

Run this once after verifying or installing win-acme. It updates both the xcopy install settings and any settings already created under `%ProgramData%\win-acme`:

```powershell
$settingsPaths = @()

$installSettings = Join-Path $wacsDir 'settings.json'
if (-not (Test-Path $installSettings)) {
  Copy-Item (Join-Path $wacsDir 'settings_default.json') $installSettings
}
$settingsPaths += $installSettings

$programDataSettings = Join-Path $env:ProgramData 'win-acme'
if (Test-Path $programDataSettings) {
  $settingsPaths += Get-ChildItem $programDataSettings -Filter 'settings.json' -Recurse |
    Select-Object -ExpandProperty FullName
}

foreach ($settingsPath in ($settingsPaths | Select-Object -Unique)) {
  $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
  $settings.Validation.PreValidateDns = $false
  $settings | ConvertTo-Json -Depth 100 | Set-Content $settingsPath -Encoding utf8
  Write-Host "Updated $settingsPath"
}
```

### 3.b. Run the manual DNS-01 challenge

Set your hostname, contact email, and PFX password:

```powershell
$hostName = '<your-hostname>'          # for example: app.contoso.com
$contactEmail = 'you@example.com'
$pfxPassword = 'temporary-pfx-password'
Write-Host "Requesting certificate for $hostName"
```

Do not continue if this prints the wrong hostname. Stop and set `$hostName` again before running win-acme, because the issued certificate must exactly match the Application Gateway hostname. If you chose `app.contoso.com`, every DNS and certificate step must use `app.contoso.com` / `_acme-challenge.app.contoso.com`, not `voicelab.example.com` or any previous hostname.

Request the certificate:

```powershell
$wacsDir = 'C:\tools\win-acme'

& "$wacsDir\wacs.exe" `
  --nocache `
  --source manual `
  --host $hostName `
  --commonname $hostName `
  --validation manual `
  --validationmode dns-01 `
  --store pfxfile `
  --pfxfilepath (Get-Location).Path `
  --pfxfilename 'voicelab' `
  --pfxpassword $pfxPassword `
  --accepttos `
  --emailaddress $contactEmail
```

On the jumpbox, win-acme may print scary-looking warnings while still succeeding. Do not stop just because you see one of these messages:

```text
Error updating public suffix list from https://publicsuffix.org/list/public_suffix_list.dat: ...
Error connection to 156.154....
Unable to contact name servers for <domain>
[HTTP] Request completed with status BadRequest
First chance error calling into ACME server, retrying with new nonce...
```

Those are expected in network-isolated environments when win-acme cannot perform some local helper checks or has to retry the ACME nonce. Continue if win-acme still prints the DNS TXT challenge, and treat the run as successful only when you later see:

```text
Authorization result: valid
Certificate [Manual] <your-hostname> created
Copying certificate to the pfx folder ...\voicelab.pfx
```

win-acme will pause and print the DNS TXT record you must create. Example:

```text
Please create the following TXT record:
_acme-challenge.<your-hostname>

with value:
abc123XYZdef456...
```

Before you create the TXT record, confirm the `Domain:` line in win-acme output is the hostname you intend to publish. If it says a different hostname, press `Ctrl+C`, reset `$hostName`, and re-run the command.

Open the DNS zone for your parent domain in your DNS provider and add the TXT record from win-acme. DNS providers differ in how they label the record-name field, so translate the win-acme output carefully:

```text
Type:  TXT
Name/Host: _acme-challenge.<your-subdomain>
Value: abc123XYZdef456...
TTL:   Automatic or 5 minutes
```

Use these rules:

1. If your provider asks for a **relative** name, omit the parent zone suffix. For example, for `_acme-challenge.app.contoso.com` in the `contoso.com` zone, enter `_acme-challenge.app`.
2. If your provider asks for the **fully qualified** record name, enter the full `_acme-challenge.<your-hostname>` value printed by win-acme.
3. Use the token from win-acme as the TXT value. If win-acme prints quotes around the value, copy the value without adding an extra set of quotes unless your DNS provider explicitly requires them.
4. Save/apply the DNS change in the provider UI before testing propagation.

> **Namecheap and similar DNS panels:** the **Host** field is relative to your zone. If your zone is `contoso.com` and win-acme asks for `_acme-challenge.app.contoso.com`, enter only `_acme-challenge.app`. If you enter the full `_acme-challenge.app.contoso.com`, the provider may create `_acme-challenge.app.contoso.com.contoso.com`, which Let's Encrypt will not find.
>
> **Do not reuse that short Host value in PowerShell.** The DNS provider's **Host** field may be relative, but `Resolve-DnsName` needs the full DNS name. For example, if the DNS panel Host is `_acme-challenge.app` in the `contoso.com` zone, test `_acme-challenge.app.contoso.com`, not `_acme-challenge.app`.

Wait until the TXT record propagates. If you are running win-acme on the jumpbox, verify propagation from your **workstation** or from a browser-based public DNS checker, not from the jumpbox. Direct DNS queries from the jumpbox to public resolvers are expected to time out in network-isolated deployments.

From your workstation:

```powershell
$txtRecord = "_acme-challenge.$hostName"
# Example: if $hostName is app.contoso.com, this becomes
# _acme-challenge.app.contoso.com. Do not shorten it.
Resolve-DnsName $txtRecord -Type TXT
Resolve-DnsName $txtRecord -Type TXT -Server 8.8.8.8
Resolve-DnsName $txtRecord -Type TXT -Server 1.1.1.1
# expected answer: the abc123XYZdef456... value
```

If you only have the jumpbox session open, use the jumpbox browser to check the TXT record with a public DNS checker over HTTPS instead of running `Resolve-DnsName ... -Server 8.8.8.8` inside PowerShell.

Do **not** press Enter in the win-acme terminal until at least one public resolver returns the exact TXT value from win-acme.

If win-acme still says the local resolver found no TXT records after you press Enter, but you already verified the TXT value with a public resolver such as `8.8.8.8` or `1.1.1.1`, choose:

```text
2: Ignore and continue
```

This skips win-acme's local pre-check and lets Let's Encrypt perform the authoritative DNS-01 validation.

After validation succeeds, win-acme may prompt you to delete the TXT record:

```text
Please press <Enter> after you've deleted the record
```

Return to your DNS provider and delete only the temporary TXT record you created for this challenge (`_acme-challenge...` with the token value from win-acme). Leave the application A record and any unrelated DNS records intact. After saving the DNS deletion in your provider UI, return to win-acme and press Enter. On success, win-acme writes the generated PFX to `.\voicelab.pfx`.

### 3.c. Confirm the generated PFX

Application Gateway and Key Vault consume the certificate in PKCS#12 (PFX) form. win-acme already generated that file:

```powershell
Get-Item .\voicelab.pfx
```

You now have `voicelab.pfx` on disk. Use the same `$pfxPassword` value in the Key Vault import step.

### 3.d. Optional alternative only: use Certbot from WSL/Linux

Skip this section if step 3.c produced `voicelab.pfx` with win-acme. It is only an alternative path for operators who choose not to use win-acme and instead want to run Certbot from WSL or a Linux machine. The native Windows Certbot installer is no longer a reliable path.

```bash
sudo apt-get install certbot
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --agree-tos \
  --email you@example.com \
  -d <your-hostname>
```

Then convert the PEM files to PFX:

```bash
openssl pkcs12 -export \
  -out voicelab.pfx \
  -inkey /etc/letsencrypt/live/<your-hostname>/privkey.pem \
  -in   /etc/letsencrypt/live/<your-hostname>/fullchain.pem \
  -passout pass:temporary-pfx-password
```

---

## 4. Import the certificate into the deployment's Key Vault

> ⚠️ **Important:** This step **must be executed from the jumpbox** (or another resource within the same virtual network), **not from your workstation**. The Key Vault has `Public network access = Disabled`, meaning only resources inside the Azure network can access it. Your workstation cannot reach it directly.

### 4.a. Import from the jumpbox

If you followed the default path in step 3, `voicelab.pfx` is already on the jumpbox. Stay in the same jumpbox PowerShell session and run the import using the `$kv` value you already copied from the helper output in step 0:

```powershell
# Use managed identity to authenticate (no interactive login needed on jumpbox)
az login --identity

# Do not reset $kv here if you already copied it from step 0.
# It should already look like: $kv = 'kv-<token>'
$certName    = 'voicelab-cert'
$pfxPassword = 'temporary-pfx-password'   # the one used in step 3.b

# Import the certificate
az keyvault certificate import `
  --vault-name $kv `
  --name       $certName `
  --file       .\voicelab.pfx `
  --password   $pfxPassword
```

If the import succeeds, you will see JSON output with the certificate details. If it fails with an authentication error, run `az login --identity` again in the same jumpbox shell and retry the import.

### 4.b. Capture the certificate secret URI

Once import succeeds, capture the **versionless** secret URI for the next step. Run this from the jumpbox:

```powershell
$secretId = "https://$kv.vault.azure.net/secrets/$certName"
Write-Host $secretId
# expected: https://kv-<token>.vault.azure.net/secrets/voicelab-cert
```

Record this value for step 5.

### 4.c. Optional only: if the PFX was created somewhere else

Skip this section if `voicelab.pfx` was generated on the jumpbox. If you chose an alternative certificate path and created the PFX on your workstation, copy it to the jumpbox before running step 4.a. The simplest options are:

1. Use Azure Bastion's **Upload / Download** file transfer feature to upload `voicelab.pfx` to the jumpbox.
2. Connect to the jumpbox through Bastion and copy the file manually.

After the file is on the jumpbox, return to step 4.a and import it into Key Vault.

---

## 5. Promote the gateway to live mode from your workstation

Live mode and skeleton mode are modeled in Bicep, so re-running `azd provision` after this step will reconcile the configuration cleanly. Do not edit the Application Gateway directly in the portal; portal-side changes will be reverted by the next provision.

Run every command in this section from **your workstation**, not from the jumpbox.

Set the public hostname and certificate secret via `azd env`:

`PUBLIC_INGRESS_FRONTEND_HOSTNAME` must be the **full public DNS hostname/FQDN** you chose in step 1 and used for the certificate in step 3. It is not the Container App hostname, and it is not the short DNS provider record name.

```powershell
azd env set PUBLIC_INGRESS_FRONTEND_HOSTNAME   $hostName
azd env set PUBLIC_INGRESS_SSL_CERT_SECRET_ID  $secretId
```

If you type the values directly instead of using variables, wrap them in single quotes in PowerShell:

```powershell
azd env set PUBLIC_INGRESS_FRONTEND_HOSTNAME   'app.contoso.com'
azd env set PUBLIC_INGRESS_SSL_CERT_SECRET_ID  'https://kv-<token>.vault.azure.net/secrets/voicelab-cert'
```

Still on your workstation, set the IP allow-list directly in [`main.parameters.json`](../../main.parameters.json):

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

Then re-provision from your workstation:

```powershell
azd provision
```

The reconcile is fast (only the gateway listener, redirect rule, NSG rule, and the cert reference change). Validate the transition:

```powershell
pwsh -File ./scripts/show-public-ingress-outputs.ps1
# expected: true
```

---

## 6. Validate end-to-end

From a workstation whose egress IP is in the allow-list:

```powershell
# HTTPS reaches the app
curl -v "https://$hostName/"
# expected: 200 OK from the Container App, valid TLS chain

# HTTP redirects to HTTPS
curl -v "http://$hostName/"
# expected: 301 to https://<your-hostname>/

# Browser test — open in Edge/Chrome on the same workstation
# expected: TLS green padlock, app loads, "Start Recording" exposes the
# real microphone (this is the whole point — secure context + real device).
```

From a workstation whose egress IP is **not** in the allow-list:

```powershell
curl -v --max-time 10 "https://$hostName/"
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

> **Caveat.** `azd`/ARM incremental deployments will **not** delete public-ingress resources when `publicIngress.enabled` flips back to `false` after a previous deploy. To actually remove the resources without `azd down`, you must delete them manually:
>
> ```powershell
> az network application-gateway delete -g $rg -n $agw
> # also delete the corresponding PIP, WAF policy, and NSG by reading their resource IDs
> # from the helper script output.
> ```

In either case, the application's internal posture (Container Apps environment with `internal=true`, private endpoints) is preserved across teardown and re-provision of the public ingress. You can flip the public ingress on and off without touching the workload.

---

## Variations

The walkthrough above uses one concrete toolchain. Each step has equivalent substitutions:

| Step | Walkthrough used | Equivalent alternatives |
|------|------------------|-------------------------|
| Domain | A registrar's DNS panel | Azure DNS zone (cheap if you already use Azure DNS); a corporate DNS zone if you control one. |
| Certificate | `win-acme` manual DNS-01 + a publicly trusted free CA | `certbot` from WSL/Linux, `Posh-ACME`, `acme.sh` or `lego` from any environment; the certificate authority of your organization (skip ACME, generate a CSR, submit, receive, build PFX); a paid commercial CA with their portal-driven flow. |
| Cert format pipeline | win-acme generated PFX | `openssl pkcs12 -export` when starting from PEM files; `New-PfxCertificate` (Windows) when the source is already a Windows cert store entry; the CA's portal if it issues PFX directly. |
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

1. Re-run step 3 with the same `$hostName` value.
2. Re-run step 3.c to confirm the fresh win-acme PFX exists at `voicelab.pfx`.
3. Re-run step 4 against the same `KEY_VAULT_NAME` and the same `voicelab-cert` name. The import creates a **new version**; the versionless `sslCertSecretId` automatically points at the latest version, so no Bicep change is required.
4. Restart the gateway listener so it picks up the new cert version:
   ```powershell
   az network application-gateway stop  --resource-group $rg --name $agw
   az network application-gateway start --resource-group $rg --name $agw
   ```
   In practice, AGW polls Key Vault every ~4 hours and rotates the cert without a restart; the explicit restart above only matters if you need the rotation immediately.

If you prefer hands-off renewals, swap the manual DNS-01 flow for an automated alternative (your registrar's API + an automation, or a managed ACME flow if available in your environment). The accelerator does not opine on this choice; the contract handed to the gateway (a versionless KV secret URI) is the same regardless of how the cert behind it was obtained.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `show-public-ingress-outputs.ps1` says `Please run 'az login'` | The Azure CLI shell is not authenticated yet. | On the jumpbox run `az login --identity`, then rerun the helper. On a workstation run `az login`. |
| `show-public-ingress-outputs.ps1` on the jumpbox still cannot read Azure resources after `az login --identity` | The shell is logged in, but this session cannot read the required management-plane values. | Use the values from the original `azd provision`, or run the helper once from your workstation. Continue win-acme and Key Vault import from the jumpbox. |
| `PUBLIC_INGRESS_ENABLED` is `false` after provision | `NETWORK_ISOLATION=false` or `PUBLIC_INGRESS_ENABLED=false`. | `azd env set NETWORK_ISOLATION true` or `azd env set PUBLIC_INGRESS_ENABLED true` and re-provision. |
| `PUBLIC_INGRESS_LIVE` stays `false` after step 5 | Either `frontendHostName` or `sslCertSecretId` is still empty on the gateway. | Re-check the two `azd env set` commands from step 5 and confirm `azd provision` re-ran. Then run `pwsh -File ./scripts/show-public-ingress-outputs.ps1` again. |
| `curl https://<your-hostname>/` returns `tls handshake timeout` from an allow-listed IP | DNS not propagated yet; or the allow-list does not include this IP. | Verify `Resolve-DnsName $hostName` returns the gateway IP, then check the NSG rule contains the IP's `/32`. |
| Browser shows certificate name mismatch | The cert was issued for a different hostname, or the listener was configured with a different hostname than the cert covers. | Re-issue the cert for the exact `frontendHostName`, or change `frontendHostName` to match. |
| Browser shows `NET::ERR_CERT_AUTHORITY_INVALID` | The CA root is not in this browser's trust store. | Use a publicly trusted CA, or import the corporate root CA on the tester's workstation. |
| win-acme fails with `Unexpected DNS error while checking <domain>` before showing the TXT record | The jumpbox/firewall cannot perform win-acme's local DNS pre-validation against external authoritative DNS servers. | Disable `Validation.PreValidateDns` in win-acme `settings.json` as shown in step 3.a, then re-run step 3.b. Still verify the TXT record yourself with public DNS before pressing Enter. |
| win-acme shows `Domain:` with the wrong hostname | `$hostName` still contains an old value from your PowerShell session. | Press `Ctrl+C`, set `$hostName` to the exact hostname you want, and re-run step 3.b. Do not issue/import a certificate for the wrong hostname. |
| `az keyvault certificate import` fails with `BadParameter: Could not parse` | The PFX password is wrong, or the PFX was produced by an incompatible toolchain. | If using win-acme, confirm the import uses the same `--pfxpassword` value from step 3.b. If using OpenSSL, re-export with a known password and standard algorithms: `openssl pkcs12 -export -legacy -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg SHA256 ...` |
| `azd provision` fails with `KeyVault user is not authorized` on the gateway | The cert is in an external KV and the AGW UAI was not granted `Key Vault Secrets User` on it. | Run the role assignment from step 4 with the external KV's resource ID. |
| `curl https://<your-hostname>/` returns `502 Bad Gateway` from an allow-listed IP | The backend pool resolved correctly but the Container App isn't responding on `/`, or the Container App's own ingress is misconfigured. | Test the Container App FQDN from inside the VNet/jumpbox. The backend pool wiring itself is correct by construction (Bicep). |

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
