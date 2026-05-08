#!/usr/bin/env pwsh
# Prints the values needed by docs/manual-testing/public-ingress-runbook.md
# Reads them straight from Azure resources so it works from anywhere that has
# `az` logged in (including the jumpbox via `az login --identity`).
#
# Usage:
#   pwsh -File ./scripts/show-public-ingress-outputs.ps1
#   pwsh -File ./scripts/show-public-ingress-outputs.ps1 -ResourceGroup rg-foo
#
# If -ResourceGroup is not provided, falls back to AZURE_RESOURCE_GROUP env var,
# then to `azd env get-value AZURE_RESOURCE_GROUP`.

[CmdletBinding()]
param(
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'

function Resolve-ResourceGroup {
    if ($ResourceGroup) { return $ResourceGroup }
    if ($env:AZURE_RESOURCE_GROUP) { return $env:AZURE_RESOURCE_GROUP }
    try {
        $rg = (azd env get-value AZURE_RESOURCE_GROUP 2>$null)
        if ($rg) { return $rg.Trim() }
    } catch {}
    throw "Resource group not found. Pass -ResourceGroup, set `$env:AZURE_RESOURCE_GROUP, or run from an azd-initialized env."
}

$rg = Resolve-ResourceGroup
Write-Host "[i] Reading public ingress outputs from resource group '$rg'..." -ForegroundColor Cyan

$agw = az network application-gateway list -g $rg --query "[0].name" -o tsv 2>$null
if (-not $agw) {
    Write-Host "[!] No Application Gateway found in '$rg'. Public ingress not provisioned?" -ForegroundColor Yellow
    exit 1
}

$agwJson = az network application-gateway show -g $rg -n $agw -o json | ConvertFrom-Json

$gwId    = $agwJson.id
$pipId   = $agwJson.frontendIPConfigurations[0].publicIPAddress.id
$pipName = Split-Path $pipId -Leaf
$ip      = az network public-ip show -g $rg -n $pipName --query ipAddress -o tsv
$miId    = $agwJson.identity.userAssignedIdentities.PSObject.Properties.Name | Select-Object -First 1
$miPid   = az identity show --ids $miId --query principalId -o tsv

$nsgs = az network nsg list -g $rg -o json | ConvertFrom-Json
$nsgId = @(
    $nsgs | Where-Object {
        $subnetIds = @($_.subnets | ForEach-Object { $_.id })
        ($subnetIds -join ';') -match '(?i)/subnets/AppGatewaySubnet$'
    } | Select-Object -ExpandProperty id -First 1
)
$kv    = az keyvault list -g $rg --query "[?!contains(name,'-ai-')].name | [0]" -o tsv

$sslCertificateCount = @($agwJson.sslCertificates).Count
$httpsListenerCount = @($agwJson.httpListeners | Where-Object { $_.name -eq 'https-listener' }).Count
$live = if ($sslCertificateCount -gt 0 -and $httpsListenerCount -gt 0) { 'true' } else { 'false' }

Write-Host ""
Write-Host "Copy these into your runbook session:" -ForegroundColor Green
Write-Host "----------------------------------------------------------------"
Write-Host "AZURE_RESOURCE_GROUP                 = $rg"
Write-Host "KEY_VAULT_NAME                       = $kv"
Write-Host "PUBLIC_INGRESS_PUBLIC_IP             = $ip"
Write-Host "PUBLIC_INGRESS_GATEWAY_RESOURCE_ID   = $gwId"
Write-Host "PUBLIC_INGRESS_NSG_RESOURCE_ID       = $nsgId"
Write-Host "PUBLIC_INGRESS_IDENTITY_PRINCIPAL_ID = $miPid"
Write-Host "PUBLIC_INGRESS_LIVE                  = $live"
Write-Host "----------------------------------------------------------------"
Write-Host ""
Write-Host "PowerShell variables for direct use:" -ForegroundColor Green
Write-Host "----------------------------------------------------------------"
Write-Host "`$rg     = '$rg'"
Write-Host "`$kv     = '$kv'"
Write-Host "`$ip     = '$ip'"
Write-Host "`$miPid  = '$miPid'"
Write-Host "`$gwId   = '$gwId'"
Write-Host "`$nsgId  = '$nsgId'"
Write-Host "`$agw    = '$agw'"
Write-Host "----------------------------------------------------------------"
