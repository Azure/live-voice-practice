<#
.SYNOPSIS
    postDeploy.ps1 - Post-deploy smoke test for Live Voice Practice (Windows).

.DESCRIPTION
    Runs after `azd deploy`. Hits /api/health on the Container App and fails
    the deploy early if the backend cannot serve scenarios.

    Connectivity strategy:
      * NETWORK_ISOLATION=false -> probe the public ingress directly.
      * NETWORK_ISOLATION=true  -> the Container App FQDN is only reachable
        from inside the VNet. From a workstation, the script uses jumpbox
        Run-Command directly instead of printing noisy expected failures.
        When run on the jumpbox itself, it probes directly.

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

function Enable-AzCliNonInteractiveExtensions {
    az config set extension.use_dynamic_install=yes_without_prompt 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Yellow "[postDeploy] Could not configure Azure CLI dynamic extension install; az extension prompts may block non-interactive runs."
    }
}

Enable-AzCliNonInteractiveExtensions

# ---------- env helpers --------------------------------------------------
$envValues = azd env get-values 2>$null
function Get-EnvVal {
    param([string]$Name)
    $line = $envValues | Select-String "^$Name=" | Select-Object -First 1
    if ($line) {
        return ($line.ToString() -replace "^$Name=`"?([^`"]*)`"?.*", '$1').Trim()
    }
    $procVal = [Environment]::GetEnvironmentVariable($Name)
    if ($procVal) { return $procVal.Trim('"').Trim() }
    return $null
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
    if ($JsonText -match 'login\.microsoftonline\.com|<title>Sign in to your account</title>') {
        Write-Yellow "[postDeploy] Health endpoint returned the Microsoft sign-in page."
        Write-Yellow "[postDeploy] Treating this as healthy because Container Apps authentication is enabled."
        return 0
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
function Resolve-JumpboxName {
    param([string]$ResourceGroup)

    $vmName = Get-EnvVal 'TEST_VM_NAME'
    if (-not $vmName) {
        $vmName = az vm list -g $ResourceGroup --query "[?contains(name, 'testvm') || contains(name, 'jumpbox')].name | [0]" -o tsv 2>$null
    }
    return $vmName
}

function Test-RunningOnJumpbox {
    param([string]$VmName)

    return ($env:COMPUTERNAME -and $VmName -and $VmName -like "$($env:COMPUTERNAME)*")
}

function Invoke-JumpboxProbe {
    param([string]$ResourceGroup, [string]$Fqdn)

    $vmName = Resolve-JumpboxName -ResourceGroup $ResourceGroup
    if (-not $vmName) {
        Write-Yellow "[postDeploy] No jumpbox VM found in $ResourceGroup; cannot probe inside VNet."
        return $null
    }

    # Avoid run-command-on-self if we happen to BE the jumpbox.
    if (Test-RunningOnJumpbox -VmName $vmName) {
        Write-Yellow "[postDeploy] We appear to be the jumpbox itself ($($env:COMPUTERNAME)); direct probe should have worked."
        return $null
    }

    Write-Blue "[postDeploy] Probing from inside the VNet via jumpbox Run-Command ($vmName)."

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
    `$raw = (`$out | Out-String).TrimEnd()
    if (`$raw -match '(?s)__HTTP__([0-9]{3})\s*$') {
        `$code = `$Matches[1]
        `$body = `$raw -replace '(?s)__HTTP__[0-9]{3}\s*$',''
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
if ($niEnabled -and -not (Test-RunningOnJumpbox -VmName (Resolve-JumpboxName -ResourceGroup $rg))) {
    Write-Blue "[postDeploy] NETWORK_ISOLATION=true; direct Container App probe from workstation is expected to be unreachable."
    $body = Invoke-JumpboxProbe -ResourceGroup $rg -Fqdn $fqdn
}
else {
    Write-Blue "[postDeploy] Probing $healthUrl ..."
    $body = Invoke-DirectProbe -Url $healthUrl
}

if (-not $body) {
    Write-Red "[postDeploy] Could not reach $healthUrl."
    Write-Yellow "  Tail of recent Container App logs:"
    az containerapp logs show -n $appName -g $rg --tail 50 2>$null
    exit 1
}

exit (Invoke-HealthCheck -JsonText $body)
