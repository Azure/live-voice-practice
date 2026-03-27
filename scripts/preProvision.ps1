Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Initializing infrastructure submodule..." -ForegroundColor Cyan
git submodule update --init --recursive
if ($LASTEXITCODE -ne 0) {
    Write-Host "Warning: Failed to initialize submodule. If infra folder is empty, provisioning will fail." -ForegroundColor Yellow
}

$projectRoot = Join-Path $PSScriptRoot ".."
$infraDir = Join-Path $projectRoot "infra"

foreach ($fileName in @("manifest.json", "main.parameters.json")) {
    $src = Join-Path $projectRoot $fileName
    $dst = Join-Path $infraDir $fileName
    if (Test-Path $src) {
        Write-Host "Applying project $fileName to infra..." -ForegroundColor Cyan
        Copy-Item -Path $src -Destination $dst -Force
    }
}

function Test-Truthy($value) {
    if (-not $value) { return $false }
    return $value -match '^(1|true|t)$'
}

$networkIsolation = $env:AZURE_NETWORK_ISOLATION
if (-not $networkIsolation) { $networkIsolation = $env:NETWORK_ISOLATION }
$skipWarning = $env:AZURE_SKIP_NETWORK_ISOLATION_WARNING

if (Test-Truthy $skipWarning) { exit 0 }

if (Test-Truthy $networkIsolation) {
    Write-Host "Warning!" -ForegroundColor Yellow -NoNewline
    Write-Host " Network isolation is enabled." -ForegroundColor Yellow
    Write-Host " - After provisioning, continue deployment from within private network access (VPN/Jumpbox)." -ForegroundColor Yellow

    $prompt = "? Continue with Zero Trust provisioning? [Y/n]: "
    Write-Host $prompt -ForegroundColor Blue -NoNewline
    $confirmation = Read-Host
    if ($confirmation -and $confirmation -notin 'Y','y') { exit 1 }
}

exit 0
