#!/usr/bin/env pwsh
# Prints the values needed by docs/manual-testing/public-ingress-runbook.md
# Reads them from deployment outputs first, then falls back to Azure resources.
# This is a management-plane helper. The jumpbox managed identity may not have
# ARM Reader permissions for deployments or network resources; in that case use
# values already printed by azd provision, or rerun this helper from your
# workstation with your Azure user login.
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

function Get-OutputValue {
    param(
        [Parameter(Mandatory)] $Outputs,
        [Parameter(Mandatory)] [string] $Name
    )
    foreach ($property in $Outputs.PSObject.Properties) {
        if ($property.Name -ieq $Name) {
            return $property.Value.value
        }
    }
    return $null
}

function Write-RunbookOutputs {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $KeyVaultName,
        [Parameter(Mandatory)] [string] $PublicIp,
        [Parameter(Mandatory)] [string] $GatewayResourceId,
        [Parameter(Mandatory)] [string] $NsgResourceId,
        [Parameter(Mandatory)] [string] $IdentityPrincipalId,
        [Parameter(Mandatory)] [string] $Live
    )

    $agw = Split-Path $GatewayResourceId -Leaf

    Write-Host ""
    Write-Host "Copy these into your runbook session:" -ForegroundColor Green
    Write-Host "----------------------------------------------------------------"
    Write-Host "AZURE_RESOURCE_GROUP                 = $ResourceGroup"
    Write-Host "KEY_VAULT_NAME                       = $KeyVaultName"
    Write-Host "PUBLIC_INGRESS_PUBLIC_IP             = $PublicIp"
    Write-Host "PUBLIC_INGRESS_GATEWAY_RESOURCE_ID   = $GatewayResourceId"
    Write-Host "PUBLIC_INGRESS_NSG_RESOURCE_ID       = $NsgResourceId"
    Write-Host "PUBLIC_INGRESS_IDENTITY_PRINCIPAL_ID = $IdentityPrincipalId"
    Write-Host "PUBLIC_INGRESS_LIVE                  = $Live"
    Write-Host "----------------------------------------------------------------"
    Write-Host ""
    Write-Host "PowerShell variables for direct use:" -ForegroundColor Green
    Write-Host "----------------------------------------------------------------"
    Write-Host "`$rg     = '$ResourceGroup'"
    Write-Host "`$kv     = '$KeyVaultName'"
    Write-Host "`$ip     = '$PublicIp'"
    Write-Host "`$miPid  = '$IdentityPrincipalId'"
    Write-Host "`$gwId   = '$GatewayResourceId'"
    Write-Host "`$nsgId  = '$NsgResourceId'"
    Write-Host "`$agw    = '$agw'"
    Write-Host "----------------------------------------------------------------"
}

$deploymentOutputs = $null
try {
    $deploymentName = az deployment group list -g $rg --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name" -o tsv 2>$null
    if ($deploymentName) {
        $deploymentOutputs = az deployment group show -g $rg -n $deploymentName --query "properties.outputs" -o json 2>$null | ConvertFrom-Json
    }
} catch {
    $deploymentOutputs = $null
}

$gwId = if ($deploymentOutputs) { Get-OutputValue $deploymentOutputs 'PUBLIC_INGRESS_GATEWAY_RESOURCE_ID' } else { $null }
$ip = if ($deploymentOutputs) { Get-OutputValue $deploymentOutputs 'PUBLIC_INGRESS_PUBLIC_IP' } else { $null }
$nsgId = if ($deploymentOutputs) { Get-OutputValue $deploymentOutputs 'PUBLIC_INGRESS_NSG_RESOURCE_ID' } else { $null }
$miPid = if ($deploymentOutputs) { Get-OutputValue $deploymentOutputs 'PUBLIC_INGRESS_IDENTITY_PRINCIPAL_ID' } else { $null }
$liveOutput = if ($deploymentOutputs) { Get-OutputValue $deploymentOutputs 'PUBLIC_INGRESS_LIVE' } else { $null }
$kv = if ($deploymentOutputs) { Get-OutputValue $deploymentOutputs 'KEY_VAULT_NAME' } else { $null }

if ($gwId -and $ip -and $nsgId -and $miPid -and $kv) {
    $live = if ($liveOutput -is [bool]) { $liveOutput.ToString().ToLowerInvariant() } else { "$liveOutput".ToLowerInvariant() }
    Write-RunbookOutputs -ResourceGroup $rg -KeyVaultName $kv -PublicIp $ip -GatewayResourceId $gwId -NsgResourceId $nsgId -IdentityPrincipalId $miPid -Live $live
    exit 0
}

$agwListOutput = az network application-gateway list -g $rg --query "[0].name" -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or -not $agwListOutput) {
    Write-Host "[!] Could not read Application Gateway resources in '$rg'." -ForegroundColor Yellow
    Write-Host "    If you are on the jumpbox with 'az login --identity', stop here: this is usually an ARM Reader permission limitation of the jumpbox managed identity, not proof that public ingress is missing." -ForegroundColor Yellow
    Write-Host "    Continue on the jumpbox using the values from your azd provision session, or rediscover them once from your workstation with your Azure user login." -ForegroundColor Yellow
    if ($agwListOutput) {
        Write-Host "    Azure CLI output: $agwListOutput" -ForegroundColor DarkYellow
    }
    exit 1
}

$agw = ($agwListOutput | Select-Object -First 1).Trim()
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

Write-RunbookOutputs -ResourceGroup $rg -KeyVaultName $kv -PublicIp $ip -GatewayResourceId $gwId -NsgResourceId $nsgId -IdentityPrincipalId $miPid -Live $live
