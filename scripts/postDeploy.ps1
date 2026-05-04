<#
.SYNOPSIS
    postDeploy.ps1 - Post-deploy smoke test for Live Voice Practice (Windows).

.DESCRIPTION
    Runs after `azd deploy`. Hits /api/health on the Container App and fails
    the deploy early if the backend cannot serve scenarios.

    Connectivity strategy:
      * NETWORK_ISOLATION=false -> probe the public ingress directly.
      * NETWORK_ISOLATION=true  -> the ingress is internal, only reachable
        from inside the VNet. The script:
          1. Probes directly first (works when run on the jumpbox via
             Bastion, since the jumpbox already lives inside the VNet
             and resolves the FQDN to its private IP).
          2. Falls back to `az vm run-command invoke` against the jumpbox
             when we're not on the jumpbox ourselves.

    SSL: the AILZ Azure Firewall blocks revocation endpoints
    (oneocsp.microsoft.com, ocsp.digicert.com, crl{2,3}.microsoft.com,
    ctldl.windowsupdate.com) until the upstream allowlist is amended.
    To keep the smoke test reliable from the jumpbox, the script
    disables CRL/OCSP checks for its own .NET probe and passes
    --ssl-no-revoke to curl on remote Windows probes. Cert validation
    (chain + hostname) still runs.

    Skip with: `azd env set SKIP_POSTDEPLOY_SMOKE_TEST true`.
#>

$ErrorActionPreference = 'Continue'

function Write-Green($msg) { Write-Host $msg -ForegroundColor Green }
function Write-Blue($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Yellow($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Red($msg) { Write-Host $msg -ForegroundColor Red }

Write-Host ""
Write-Blue "[postDeploy] Running smoke test..."

# ---------- env helpers --------------------------------------------------
$envValues = azd env get-values 2>$null
function Get-EnvVal {
    param([string]$Name)
    $procVal = [Environment]::GetEnvironmentVariable($Name)
    if ($procVal) { return $procVal.Trim('"') }
    $line = $envValues | Select-String "^$Name=" | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line.ToString() -replace "^$Name=`"?([^`"]*)`"?.*", '$1')
}

$rg = Get-EnvVal 'AZURE_RESOURCE_GROUP'
$networkIsolation = Get-EnvVal 'NETWORK_ISOLATION'
$skip = Get-EnvVal 'SKIP_POSTDEPLOY_SMOKE_TEST'

if ($skip -eq 'true') {
    Write-Yellow "[postDeploy] SKIP_POSTDEPLOY_SMOKE_TEST=true - skipping"
    exit 0
}
if (-not $rg) {
    Write-Yellow "[postDeploy] AZURE_RESOURCE_GROUP not set; skipping smoke test"
    exit 0
}

$appName = Get-EnvVal 'VOICELAB_APP_NAME'
if (-not $appName) {
    $appName = az containerapp list -g $rg --query "[?contains(name, 'voicelab')].name | [0]" -o tsv 2>$null
    if (-not $appName) {
        $appName = az containerapp list -g $rg --query "[0].name" -o tsv 2>$null
    }
}
if (-not $appName) {
    Write-Yellow "[postDeploy] Container App not found in $rg; skipping smoke test"
    exit 0
}

$fqdn = az containerapp show --name $appName --resource-group $rg --query 'properties.configuration.ingress.fqdn' -o tsv 2>$null
if (-not $fqdn) {
    Write-Yellow "[postDeploy] Could not resolve Container App FQDN; skipping smoke test"
    exit 0
}

$niEnabled = $networkIsolation -match '^(true|True|1|yes|YES)$'
$healthUrl = "https://$fqdn/api/health"

# ---------- health classifier --------------------------------------------
function Invoke-HealthCheck {
    param([string]$JsonText)

    if (-not $JsonText) {
        Write-Red "[postDeploy] Empty response from $healthUrl"
        return 2
    }
    try {
        $body = $JsonText | ConvertFrom-Json
    }
    catch {
        Write-Red "[postDeploy] Non-JSON response from $healthUrl"
        Write-Host $JsonText
        return 2
    }

    $scenarios = $body.checks.scenarios
    $status = if ($scenarios) { $scenarios.status } else { $body.status }

    switch ($status) {
        'ok' {
            $count = if ($scenarios) { $scenarios.scenarios_loaded } else { '?' }
            Write-Green "[postDeploy] Health OK - scenarios_loaded=$count"
            return 0
        }
        'degraded_no_cosmos' {
            Write-Yellow "[postDeploy] Health degraded (no Cosmos client)."
            Write-Yellow "  last_error: $($scenarios.last_error)"
            return 0
        }
        'degraded_config_missing' {
            Write-Yellow "[postDeploy] Health degraded (config missing)."
            Write-Yellow "  last_error: $($scenarios.last_error)"
            return 0
        }
        'degraded_auth_failure' {
            Write-Red "[postDeploy] Health DEGRADED (auth failure) - Cosmos unreachable via managed identity."
            Write-Red "  last_error: $($scenarios.last_error)"
            Write-Red ""
            Write-Red "  Likely the Container Apps IMDS sidecar issue. Try:"
            Write-Red "    az containerapp revision restart -g $rg -n $appName --revision <latest>"
            return 1
        }
        default {
            Write-Yellow "[postDeploy] Unknown health status '$status' - treating as non-blocking"
            Write-Host $JsonText
            return 0
        }
    }
}

# ---------- direct probe (works locally when NI=false, and on jumpbox when NI=true) ----
function Invoke-DirectProbe {
    param([string]$Url)

    # Cert revocation servers are typically blocked by the AILZ firewall;
    # disable revocation checks while keeping chain+hostname validation.
    [Net.ServicePointManager]::CheckCertificateRevocationList = $false
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    for ($i = 1; $i -le 6; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            return $resp.Content
        }
        catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) {
                try {
                    $reader = New-Object System.IO.StreamReader($r.GetResponseStream())
                    return $reader.ReadToEnd()
                }
                catch {}
            }
            Write-Yellow "  attempt $i/6 failed: $($_.Exception.Message); retrying in 10s..."
            Start-Sleep -Seconds 10
        }
        catch {
            Write-Yellow "  attempt $i/6 failed: $($_.Exception.Message); retrying in 10s..."
            Start-Sleep -Seconds 10
        }
    }
    return $null
}

# ---------- jumpbox fallback (only when running OUTSIDE the VNet with NI=true) ----
function Invoke-JumpboxProbe {
    param([string]$ResourceGroup, [string]$Fqdn)

    $vmName = Get-EnvVal 'TEST_VM_NAME'
    if (-not $vmName) {
        $vmName = az vm list -g $ResourceGroup --query "[?contains(name, 'testvm') || contains(name, 'jumpbox')].name | [0]" -o tsv 2>$null
    }
    if (-not $vmName) {
        Write-Yellow "[postDeploy] No jumpbox VM found in $ResourceGroup; cannot probe inside VNet."
        return $null
    }

    # Avoid run-command-on-self if we happen to BE the jumpbox.
    if ($env:COMPUTERNAME -and $vmName -like "$($env:COMPUTERNAME)*") {
        Write-Yellow "[postDeploy] We appear to be the jumpbox itself ($($env:COMPUTERNAME)); direct probe should have worked."
        return $null
    }

    Write-Blue "[postDeploy] Falling back to jumpbox Run-Command via $vmName"

    $vmState = az vm get-instance-view -g $ResourceGroup -n $vmName --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv 2>$null
    $startedByUs = $false
    if ($vmState -ne 'PowerState/running') {
        Write-Yellow "[postDeploy] Jumpbox is not running ($vmState) - starting..."
        az vm start -g $ResourceGroup -n $vmName 2>$null | Out-Null
        $startedByUs = $true
    }

    try {
        # Use PowerShell on the (Windows) jumpbox; --ssl-no-revoke handles the
        # blocked CRL/OCSP firewall paths until upstream allowlist is amended.
        $probeScript = @"
for (`$i = 1; `$i -le 6; `$i++) {
    `$out = curl.exe -sS --ssl-no-revoke -m 30 -w '__HTTP__%{http_code}' 'https://$Fqdn/api/health' 2>&1
    if (`$out -match '__HTTP__([0-9]{3})$') {
        `$code = `$Matches[1]
        `$body = `$out -replace '__HTTP__[0-9]{3}$',''
        if (`$code -match '^2[0-9][0-9]$') { Write-Output `$body; exit 0 }
    }
    Start-Sleep -Seconds 10
}
Write-Output 'PROBE_FAILED'
exit 1
"@
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $probeScript -Encoding UTF8
        $rcOutput = az vm run-command invoke -g $ResourceGroup -n $vmName --command-id RunPowerShellScript --scripts "@$tmp" --query 'value[0].message' -o tsv 2>$null
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return $rcOutput
    }
    finally {
        if ($startedByUs) {
            Write-Blue "[postDeploy] Deallocating jumpbox we started..."
            az vm deallocate -g $ResourceGroup -n $vmName --no-wait 2>$null | Out-Null
        }
    }
}

# ---------- main ----------------------------------------------------------
Write-Blue "[postDeploy] Probing $healthUrl ..."
$body = Invoke-DirectProbe -Url $healthUrl

if (-not $body -and $niEnabled) {
    Write-Yellow "[postDeploy] Direct probe failed; trying jumpbox fallback (NETWORK_ISOLATION=true)."
    $body = Invoke-JumpboxProbe -ResourceGroup $rg -Fqdn $fqdn
}

if (-not $body) {
    Write-Red "[postDeploy] Could not reach $healthUrl."
    Write-Yellow "  Tail of recent Container App logs:"
    az containerapp logs show -n $appName -g $rg --tail 50 2>$null
    exit 1
}

exit (Invoke-HealthCheck -JsonText $body)
