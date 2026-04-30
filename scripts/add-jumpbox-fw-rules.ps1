<#
.SYNOPSIS
  Adds an Application Rule Collection to the network-isolation Azure Firewall
  Policy so the jumpbox VM can reach the public FQDNs required to bootstrap
  tooling (Chocolatey, Python, Docker, GitHub, Microsoft downloads, etc.) and
  run the post-provision / deploy steps from docs/network-isolation-jumpbox-runbook.md.

.DESCRIPTION
  Idempotent: creates a dedicated Rule Collection Group ("JumpboxBootstrapRCG")
  so it never mutates the rules deployed by main.bicep. Safe to re-run — the
  Application Rule Collection is removed and re-added with the current FQDN
  list each time.

  Must be executed from a workstation with Azure CLI logged in as a principal
  that has "Microsoft.Network/firewallPolicies/ruleCollectionGroups/write" on
  the target resource group (for example, Network Contributor or Contributor).

.PARAMETER ResourceGroup
  Resource group that contains the Firewall Policy. Defaults to
  AZURE_RESOURCE_GROUP from the currently selected azd environment.

.PARAMETER JumpboxSubnetCidr
  CIDR of the jumpbox subnet (source for the allow rule). Defaults to the
  address prefix of the 'jumpbox-subnet' on the VNet deployed into the
  resource group.

.PARAMETER SubscriptionId
  Defaults to AZURE_SUBSCRIPTION_ID from the azd environment, falling back to
  the live-voice dev subscription.

.EXAMPLE
  # Run from the repo root with the azd env already selected
  ./scripts/add-jumpbox-fw-rules.ps1

.EXAMPLE
  # Explicit override
  ./scripts/add-jumpbox-fw-rules.ps1 -ResourceGroup 'rg-voice-live-ni-20260424' -JumpboxSubnetCidr '192.168.3.64/27'
#>

[CmdletBinding()]
Param(
    [string] $ResourceGroup,

    [string] $JumpboxSubnetCidr,

    [string] $SubscriptionId,

    [string] $JumpboxSubnetName = 'jumpbox-subnet',

    [string] $RuleCollectionGroupName = 'JumpboxBootstrapRCG',

    [int] $RuleCollectionGroupPriority = 500,

    [string] $CollectionName = 'AllowJumpboxBootstrap',

    [int] $CollectionPriority = 1000
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Fail {
    param([string] $Message, [string] $Hint)
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    if ($Hint) { Write-Host "Hint : $Hint" -ForegroundColor Yellow }
    exit 1
}

function Invoke-Az {
    <#
      Runs an az CLI command, capturing stdout and stderr separately so that
      Python UserWarning noise emitted by CLI extensions never contaminates
      values returned via --query (e.g. resource names). On failure, surfaces
      the actual stderr from az with the exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]] $Args,
        [string] $ActionDescription,
        [switch] $AllowFailure
    )
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & az @Args 2>$errFile
        $code   = $LASTEXITCODE
        $stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }

    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        $errText = if ($stderr) { $stderr.Trim() } else { ($stdout | Out-String).Trim() }
        Fail -Message "az CLI failed while $ActionDescription (exit $code)." `
             -Hint   "az stderr:`n$errText"
    }
    return $stdout
}

# Verify az CLI is available before doing anything else
try {
    $null = & az version --output none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "az returned $LASTEXITCODE" }
} catch {
    Fail -Message "Azure CLI (az) is not installed or not on PATH." `
         -Hint   "Install from https://aka.ms/installazurecli and ensure 'az' runs in this shell."
}

# ---------------------------------------------------------------------------
# Read defaults from the selected azd environment (if available)
# ---------------------------------------------------------------------------
function Get-AzdEnvValues {
    try {
        $raw = & azd env get-values 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @{} }
        $map = @{}
        foreach ($line in $raw) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*"?(.*?)"?\s*$') {
                $map[$matches[1]] = $matches[2]
            }
        }
        return $map
    } catch {
        return @{}
    }
}

$azdEnv = Get-AzdEnvValues

if (-not $SubscriptionId) {
    $SubscriptionId = $azdEnv['AZURE_SUBSCRIPTION_ID']
    if (-not $SubscriptionId) { $SubscriptionId = '9788a92c-2f71-4629-8173-7ad449cb50e1' }
}
if (-not $ResourceGroup) {
    $ResourceGroup = $azdEnv['AZURE_RESOURCE_GROUP']
}
if (-not $ResourceGroup) {
    Fail -Message "Resource group not provided and AZURE_RESOURCE_GROUP missing from azd env." `
         -Hint   "Run 'azd env select <name>' in this folder, or pass -ResourceGroup explicitly."
}

Write-Host "Subscription : $SubscriptionId" -ForegroundColor Cyan
Write-Host "ResourceGroup: $ResourceGroup" -ForegroundColor Cyan

Invoke-Az -ActionDescription "setting active subscription" `
    -Args @('account','set','--subscription',$SubscriptionId) | Out-Null

# Confirm the RG actually exists in this subscription
$rgProbe = Invoke-Az -AllowFailure `
    -Args @('group','show','--name',$ResourceGroup,'--query','name','-o','tsv')
if (-not $rgProbe) {
    Fail -Message "Resource group '$ResourceGroup' was not found in subscription $SubscriptionId." `
         -Hint   "Check 'az group list -o table' or pass -ResourceGroup/-SubscriptionId correctly."
}

# ---------------------------------------------------------------------------
# Resolve jumpbox-subnet CIDR if not supplied
# ---------------------------------------------------------------------------
if (-not $JumpboxSubnetCidr) {
    Write-Host "Looking up '$JumpboxSubnetName' CIDR in $ResourceGroup ..." -ForegroundColor Cyan
    $vnetName = Invoke-Az -ActionDescription "listing VNets in $ResourceGroup" `
        -Args @('network','vnet','list','--resource-group',$ResourceGroup,'--query','[0].name','-o','tsv')
    $vnetName = ($vnetName | Out-String).Trim()
    if (-not $vnetName) {
        Fail -Message "No VNet found in resource group '$ResourceGroup'." `
             -Hint   "Provision has not completed or the wrong RG was selected. Pass -JumpboxSubnetCidr to bypass."
    }

    $subnetCidr = Invoke-Az -AllowFailure `
        -Args @('network','vnet','subnet','show',
                '--resource-group',$ResourceGroup,
                '--vnet-name',$vnetName,
                '--name',$JumpboxSubnetName,
                '--query','addressPrefix','-o','tsv')
    $JumpboxSubnetCidr = ($subnetCidr | Out-String).Trim()
    if (-not $JumpboxSubnetCidr) {
        Fail -Message "Subnet '$JumpboxSubnetName' not found on VNet '$vnetName'." `
             -Hint   "Check the subnet name in the portal (VNet -> Subnets) and pass -JumpboxSubnetName or -JumpboxSubnetCidr."
    }
    Write-Host "Resolved $JumpboxSubnetName -> $JumpboxSubnetCidr (VNet: $vnetName)" -ForegroundColor Green
} else {
    Write-Host "JumpboxSubnetCidr: $JumpboxSubnetCidr (supplied)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Locate the Firewall Policy in the resource group
# ---------------------------------------------------------------------------
$policyName = Invoke-Az -ActionDescription "listing Firewall Policies in $ResourceGroup" `
    -Args @('network','firewall','policy','list','--resource-group',$ResourceGroup,'--query','[0].name','-o','tsv')
$policyName = ($policyName | Out-String).Trim()

if (-not $policyName) {
    Fail -Message "No Firewall Policy found in resource group '$ResourceGroup'." `
         -Hint   "Azure Firewall is only deployed when NETWORK_ISOLATION=true. Confirm provision succeeded, or target the correct RG."
}
Write-Host "Firewall Policy: $policyName" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Ensure the dedicated Rule Collection Group exists
# ---------------------------------------------------------------------------
$existingRcg = Invoke-Az -AllowFailure `
    -Args @('network','firewall','policy','rule-collection-group','show',
            '--policy-name',$policyName,
            '--resource-group',$ResourceGroup,
            '--name',$RuleCollectionGroupName)

if (-not $existingRcg) {
    Write-Host "Creating rule-collection-group $RuleCollectionGroupName (priority $RuleCollectionGroupPriority) ..." -ForegroundColor Yellow
    Invoke-Az -ActionDescription "creating rule-collection-group $RuleCollectionGroupName" `
        -Args @('network','firewall','policy','rule-collection-group','create',
                '--policy-name',$policyName,
                '--resource-group',$ResourceGroup,
                '--name',$RuleCollectionGroupName,
                '--priority',$RuleCollectionGroupPriority) | Out-Null
} else {
    Write-Host "Rule-collection-group $RuleCollectionGroupName already exists - refreshing collection." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# FQDNs required by install.ps1 (CSE) and the jumpbox runbook steps
# ---------------------------------------------------------------------------
$fqdns = @(
    # Microsoft downloads / VC++ Redistributable (fixes the vcredist140 404)
    'download.visualstudio.microsoft.com'
    '*.visualstudio.microsoft.com'
    'download.microsoft.com'
    '*.download.microsoft.com'

    # azd Bicep CLI auto-download (fixes "Failed: Downloading Bicep" on
    # `azd env refresh` / `azd provision` from the jumpbox)
    'downloads.bicep.azure.com'

    # Python / pip
    'www.python.org'
    '*.python.org'
    'pypi.org'
    '*.pypi.org'
    'files.pythonhosted.org'
    '*.pythonhosted.org'

    # GitHub (repo clone, release assets, buildx)
    'github.com'
    '*.github.com'
    'objects.githubusercontent.com'
    '*.githubusercontent.com'
    'codeload.github.com'

    # Chocolatey + NuGet mirrors
    'community.chocolatey.org'
    'packages.chocolatey.org'
    '*.chocolatey.org'
    'api.nuget.org'
    'www.nuget.org'
    'dist.nuget.org'

    # npm (if frontend build runs on the VM)
    'registry.npmjs.org'
    '*.npmjs.org'

    # Azure / Entra control plane
    'login.microsoftonline.com'
    'login.windows.net'
    'management.azure.com'
    'graph.microsoft.com'
    'aka.ms'
    'go.microsoft.com'

    # Docker engine + buildx + base images
    'download.docker.com'
    '*.docker.com'
    'mcr.microsoft.com'
    '*.data.mcr.microsoft.com'

    # Docker Hub (pulls for moby/buildkit, base images, etc.)
    'registry-1.docker.io'
    'auth.docker.io'
    'production.cloudflare.docker.com'
    'index.docker.io'
    'hub.docker.com'
    '*.docker.io'

    # Azure data-plane FQDNs — resolved via Private DNS, allow-listed as a safety net
    '*.azurecr.io'
    '*.blob.core.windows.net'
    '*.azconfig.io'
    '*.search.windows.net'
    '*.documents.azure.com'
    '*.vault.azure.net'
    '*.cognitiveservices.azure.com'
    '*.openai.azure.com'
)

# ---------------------------------------------------------------------------
# Reapply the Application Rule Collection (remove + add for idempotency)
# ---------------------------------------------------------------------------
Write-Host "Removing existing collection $CollectionName (if present) ..." -ForegroundColor Yellow
Invoke-Az -AllowFailure `
    -Args @('network','firewall','policy','rule-collection-group','collection','remove',
            '--policy-name',$policyName,
            '--resource-group',$ResourceGroup,
            '--rule-collection-group-name',$RuleCollectionGroupName,
            '--name',$CollectionName) | Out-Null

Write-Host "Adding Application Rule Collection $CollectionName with $($fqdns.Count) FQDNs ..." -ForegroundColor Cyan
$addArgs = @(
    'network','firewall','policy','rule-collection-group','collection','add-filter-collection',
    '--policy-name',$policyName,
    '--resource-group',$ResourceGroup,
    '--rule-collection-group-name',$RuleCollectionGroupName,
    '--name',$CollectionName,
    '--collection-priority',$CollectionPriority,
    '--action','Allow',
    '--rule-type','ApplicationRule',
    '--rule-name','allow-bootstrap-fqdns',
    '--source-addresses',$JumpboxSubnetCidr,
    '--protocols','Https=443',
    '--target-fqdns'
) + $fqdns

Invoke-Az -ActionDescription "creating Application Rule Collection $CollectionName" `
    -Args $addArgs | Out-Null

Write-Host ""
Write-Host "Done. Firewall rule applied." -ForegroundColor Green
Write-Host "Inspect with:" -ForegroundColor Green
Write-Host "  az network firewall policy rule-collection-group show ``"
Write-Host "      --resource-group $ResourceGroup ``"
Write-Host "      --policy-name $policyName ``"
Write-Host "      --name $RuleCollectionGroupName -o jsonc"
