<#
.SYNOPSIS
    deploy.ps1 - Build with 'az acr build' and update the container app.
.DESCRIPTION
    - Loads azd env.
    - Reads ACR / Container App values from App Configuration.
    - Builds and pushes the image with 'az acr build':
        - NETWORK_ISOLATION=true  -> uses the ACR Tasks agent pool
          (ACR_TASK_AGENT_POOL output from the landing zone, v1.1.0+) so the
          build runs inside the VNet and pushes to the private ACR over its
          private endpoint. No Docker required on this machine.
        - NETWORK_ISOLATION=false -> uses the shared Microsoft-managed ACR
          Tasks pool. No Docker required either.
    - Updates the voicelab container app and restarts the latest revision.
#>

#region Helper functions
function Write-Green($msg) { Write-Host $msg -ForegroundColor Green }
function Write-Blue($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Yellow($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-ErrorColored($msg) { Write-Host $msg -ForegroundColor Red }
#endregion

Write-Host ""

#region Load azd env
# When invoked as an azd hook, azd injects env values as process env vars
# (e.g. NETWORK_ISOLATION, ACR_TASK_AGENT_POOL). Recursive `azd env get-values`
# from inside a running hook can return empty in some azd versions, so we
# prefer process env vars and only fall back to parsing.
$envValues = azd env get-values 2>$null
function Get-AzdEnvValue {
    param([string]$Name)
    $procVal = [Environment]::GetEnvironmentVariable($Name)
    if ($procVal) { return $procVal.Trim('"') }
    $line = $envValues | Select-String "^$Name=" | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line.ToString() -replace "^$Name=`"?([^`"]*)`"?.*",'$1')
}
$niFlag    = Get-AzdEnvValue 'NETWORK_ISOLATION'
$agentPool = Get-AzdEnvValue 'ACR_TASK_AGENT_POOL'
#endregion

#region Read APP_CONFIG_ENDPOINT
if ($env:APP_CONFIG_ENDPOINT) {
    $APP_CONFIG_ENDPOINT = $env:APP_CONFIG_ENDPOINT.Trim()
    Write-Green "Using APP_CONFIG_ENDPOINT from environment: $APP_CONFIG_ENDPOINT"
} else {
    Write-Blue "Looking up APP_CONFIG_ENDPOINT from azd env..."
    $APP_CONFIG_ENDPOINT = ($envValues | Select-String '^APP_CONFIG_ENDPOINT=' | ForEach-Object { $_ -replace '.*=\s*"?([^"]+)"?.*','$1' } | Select-Object -First 1)
}
if (-not $APP_CONFIG_ENDPOINT) {
    Write-Yellow "APP_CONFIG_ENDPOINT not found"
    Write-Host "    Set it with: azd env set APP_CONFIG_ENDPOINT <endpoint>"
    exit 1
}
Write-Green "APP_CONFIG_ENDPOINT: $APP_CONFIG_ENDPOINT"

$configName = $APP_CONFIG_ENDPOINT -replace 'https?://','' -replace '\.azconfig\.io.*',''
Write-Green "App Configuration name: $configName"
Write-Host ""
#endregion

#region Check Azure CLI login
Write-Blue "Checking Azure CLI login..."
try {
    az account show | Out-Null
} catch {
    Write-Yellow "Not logged in. Run 'az login'."
    exit 1
}
Write-Green "Azure CLI logged in"
Write-Host ""
#endregion

#region Read values from App Configuration
$label = "live-voice-practice"
Write-Blue "Loading values from App Configuration (label=$label)..."

function Get-ConfigValue {
    param([string]$Key)
    Write-Blue "Fetching '$Key'..."
    $val = az appconfig kv show --name $configName --key $Key --label $label --auth-mode login --query value -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($val)) {
        Write-Yellow "Key '$Key' not found"
        return $null
    }
    return $val.Trim()
}

$acrName = Get-ConfigValue -Key 'CONTAINER_REGISTRY_NAME'
$acrServer = Get-ConfigValue -Key 'CONTAINER_REGISTRY_LOGIN_SERVER'
$rg = Get-ConfigValue -Key 'AZURE_RESOURCE_GROUP'
$appName = Get-ConfigValue -Key 'VOICELAB_APP_NAME'

# Fallback to ARM control plane (works when App Config data plane is unreachable,
# e.g. NETWORK_ISOLATION=true with private endpoint only). These are not secrets.
if (-not $rg) {
    $rg = ($envValues | Select-String '^AZURE_RESOURCE_GROUP=' | ForEach-Object { $_ -replace '.*=\s*"?([^"]+)"?.*','$1' } | Select-Object -First 1)
    if (-not $rg) {
        $envName = ($envValues | Select-String '^AZURE_ENV_NAME=' | ForEach-Object { $_ -replace '.*=\s*"?([^"]+)"?.*','$1' } | Select-Object -First 1)
        if ($envName) { $rg = "rg-$envName" }
    }
    if ($rg) { Write-Yellow "Using AZURE_RESOURCE_GROUP from azd env: $rg" }
}
if ($rg -and (-not $acrName -or -not $acrServer)) {
    $acrName = az acr list -g $rg --query "[0].name" -o tsv 2>$null
    if ($acrName) {
        $acrServer = az acr show -g $rg -n $acrName --query loginServer -o tsv 2>$null
        Write-Yellow "Using ACR from control plane: $acrName ($acrServer)"
    }
}
if ($rg -and -not $appName) {
    $appName = az containerapp list -g $rg --query "[?contains(name, 'voicelab')].name | [0]" -o tsv 2>$null
    if (-not $appName) {
        $appName = az containerapp list -g $rg --query "[0].name" -o tsv 2>$null
    }
    if ($appName) { Write-Yellow "Using Container App from control plane: $appName" }
}

if (-not $acrName -or -not $acrServer -or -not $rg -or -not $appName) {
    Write-ErrorColored "Required values missing (App Config + control plane fallback both failed)"
    Write-Host "   acrName=$acrName acrServer=$acrServer rg=$rg appName=$appName"
    exit 1
}

Write-Green "Values loaded:"
Write-Host "   CONTAINER_REGISTRY_NAME = $acrName"
Write-Host "   CONTAINER_REGISTRY_LOGIN_SERVER = $acrServer"
Write-Host "   AZURE_RESOURCE_GROUP = $rg"
Write-Host "   VOICELAB_APP_NAME = $appName"
Write-Host ""
#endregion

#region Decide agent pool
$agentPoolArgs = @()
if ($niFlag -eq 'true') {
    # Local azd env / process env may not have ACR_TASK_AGENT_POOL when this
    # script is invoked from a machine where azd was not the original
    # provisioner (e.g. the jumpbox after `azd provision` ran on a dev box).
    # Fall back to querying Azure directly: the AILZ landing zone deploys
    # a single agent pool on the registry under NI.
    if (-not $agentPool) {
        Write-Blue "ACR_TASK_AGENT_POOL not found in env; querying Azure (az acr agentpool list)..."
        $agentPool = az acr agentpool list -r $acrName -g $rg --query "[0].name" -o tsv 2>$null
        if ($agentPool) { $agentPool = $agentPool.Trim() }
    }
    if (-not $agentPool) {
        Write-ErrorColored "NETWORK_ISOLATION=true but no ACR Task agent pool was found."
        Write-Host "    Tried: env var, azd env, az acr agentpool list -r $acrName -g $rg"
        Write-Host "    Re-run 'azd provision' to ensure the landing zone v1.1.0+ deployed the agent pool,"
        Write-Host "    or run 'azd env refresh' on this machine to sync outputs."
        exit 1
    }
    Write-Green "Using ACR Tasks agent pool: $agentPool (VNet-attached)"
    $agentPoolArgs = @('--agent-pool', $agentPool)
} else {
    Write-Green "Using ACR shared agent pool (public network)"
}
Write-Host ""
#endregion

#region Define tag
Write-Blue "Defining tag..."
$tag = git rev-parse --short HEAD 2>$null
if (-not $tag) {
    $tag = Get-Date -Format 'yyyyMMddHHmmss'
    Write-Yellow "Git not available, using timestamp: $tag"
} else {
    $dirty = git status --porcelain 2>$null
    if ($dirty) {
        $suffix = Get-Date -Format 'yyyyMMddHHmmss'
        $tag = "$tag-dirty-$suffix"
    }
}
$imageRef = "voicelab:$tag"
$imageRefLatest = "voicelab:latest"
$imageName = "$acrServer/$imageRef"
Write-Green "Tag: $tag"
Write-Green "Image: $imageName"
Write-Host ""
#endregion

#region Stage build context (skip heavy local-only dirs)
# 'az acr build .' walks every file in the working tree to apply .dockerignore,
# which is pathologically slow on Windows when frontend/node_modules and .venv
# are present (tens of thousands of small files). We stage only what the
# Dockerfile needs into a temp directory and point az acr build at it.
Write-Blue "Staging build context..."
$stageDir = Join-Path ([System.IO.Path]::GetTempPath()) ("voicelab-src-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $stageDir | Out-Null
$excludeDirs = @(
    '.git','.azure','.venv','.temp','.pytest_cache','.mypy_cache',
    'node_modules','dist','build','infra','docs','__pycache__'
)
$excludeFiles = @('*.log','*.pyc')
# robocopy: /MIR copies the tree, /XD excludes dirs anywhere in the tree, /XF excludes files,
# /NFL /NDL /NJH /NJS /NP keep output quiet. Exit codes 0-7 are success.
$robocopyArgs = @('.', $stageDir, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1', '/XD') + $excludeDirs + @('/XF') + $excludeFiles
& robocopy @robocopyArgs | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-ErrorColored "robocopy failed (exit $LASTEXITCODE)"
    exit 1
}
$stageSize = (Get-ChildItem $stageDir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$stageCount = (Get-ChildItem $stageDir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Green ("Context: {0} ({1:N1} MB, {2} files)" -f $stageDir, ($stageSize / 1MB), $stageCount)
Write-Host ""
#endregion

#region Build and push via ACR Tasks
Write-Green "Building and pushing with 'az acr build'..."
# Pass --no-logs: az CLI's log streamer crashes on Windows cp1252 consoles
# when build output contains unicode (e.g. vite checkmarks). The build still
# runs to completion and returns a non-zero exit code on failure.
$acrBuildArgs = @(
    'acr', 'build',
    '--registry', $acrName,
    '--resource-group', $rg,
    '--platform', 'linux/amd64',
    '--image', $imageRef,
    '--image', $imageRefLatest,
    '--file', 'Dockerfile',
    '--no-logs'
) + $agentPoolArgs + @($stageDir)
try {
    az @acrBuildArgs
    $buildExit = $LASTEXITCODE
} finally {
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($buildExit -ne 0) {
    Write-ErrorColored "'az acr build' failed (exit $buildExit). Fetching latest run logs..."
    $latest = az acr task list-runs --registry $acrName --top 1 --query '[0].runId' -o tsv 2>$null
    if ($latest) {
        $sub = az account show --query id -o tsv
        $sasUrl = az rest --method post --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ContainerRegistry/registries/$acrName/runs/$latest/listLogSasUrl?api-version=2019-04-01" --query logLink -o tsv 2>$null
        if ($sasUrl) {
            Write-Yellow "==== Run $latest log (last 60 lines) ===="
            try {
                $logBytes = (Invoke-WebRequest -Uri $sasUrl -UseBasicParsing).Content
                $logText = [System.Text.Encoding]::UTF8.GetString($logBytes)
                ($logText -split "`n") | Select-Object -Last 60 | ForEach-Object { Write-Host $_ }
            } catch {
                Write-Yellow "Could not download log: $_"
            }
            Write-Yellow "==== end log ===="
        }
    }
    exit 1
}
Write-Green "Image built and pushed"
Write-Host ""
#endregion

#region Update container app
Write-Green "Updating container app..."
# Retry loop for the AcrPull race: when SystemAssigned MI was just bound to
# the Container Registry, the AcrPull role assignment can take 30-120s to
# propagate and the first 'containerapp update --image' fails with
# UNAUTHORIZED. We retry only on auth-shaped errors; any other failure
# fails fast.
$maxAttempts = 5
$backoffSeconds = @(15, 30, 60, 120)
$updateOk = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $tmpErr = New-TemporaryFile
    az containerapp update --name $appName --resource-group $rg --image $imageName 2>$tmpErr
    $exit = $LASTEXITCODE
    $errText = ''
    try { $errText = (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue) } catch { $errText = '' }
    Remove-Item $tmpErr -ErrorAction SilentlyContinue
    if ($exit -eq 0) {
        $updateOk = $true
        break
    }
    $isAuthRace = $false
    if ($errText) {
        if ($errText -match '(?i)UNAUTHORIZED|denied|pull access denied|AuthorizationFailed|InvalidAuthenticationToken') {
            $isAuthRace = $true
        }
    }
    if (-not $isAuthRace) {
        if ($errText) { Write-Host $errText }
        Write-ErrorColored "Failed to update container app (non-retryable error)"
        exit 1
    }
    if ($attempt -ge $maxAttempts) {
        if ($errText) { Write-Host $errText }
        Write-ErrorColored "Failed to update container app after $maxAttempts attempts (AcrPull role propagation timeout)"
        Write-Host "    Manual fix: confirm the Container App MI has AcrPull on the registry, then re-run azd deploy."
        exit 1
    }
    $sleep = $backoffSeconds[[Math]::Min($attempt - 1, $backoffSeconds.Count - 1)]
    Write-Yellow "AcrPull race detected (attempt $attempt/$maxAttempts) — sleeping ${sleep}s before retry..."
    Start-Sleep -Seconds $sleep
}
if (-not $updateOk) {
    Write-ErrorColored "Failed to update container app"
    exit 1
}
Write-Green "Container app updated"
Write-Host ""
#endregion

#region Restart revision
Write-Blue "Restarting revision..."
$revision = az containerapp revision list --name $appName --resource-group $rg --query '[0].name' -o tsv
if ($revision) {
    az containerapp revision restart --name $appName --resource-group $rg --revision $revision
    Write-Green "Revision restarted: $revision"
}
#endregion

Write-Host ""
Write-Green "Deploy completed successfully!"
Write-Host "   Image: $imageName"
Write-Host ""
