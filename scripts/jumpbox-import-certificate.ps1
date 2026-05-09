# Jumpbox certificate import script
# This script authenticates using managed identity and imports the PFX to Key Vault
# Run this FROM the jumpbox after transferring voicelab.pfx there

param(
  [string]$KeyVaultName = 'kv-7guer4i32clga',
  [string]$CertificateName = 'voicelab-cert',
  [string]$PfxPassword = 'myP@ssw0rd123456',
  [string]$PfxPath = '.\voicelab.pfx'
)

Write-Host "=== Jumpbox Certificate Import ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Authenticate with managed identity
Write-Host "1. Authenticating with managed identity..."
$loginResult = az login --identity 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to authenticate with managed identity" -ForegroundColor Red
  Write-Host $loginResult
  exit 1
}
Write-Host "[OK] Authenticated" -ForegroundColor Green
Write-Host ""

# Step 2: Verify PFX exists
Write-Host "2. Checking PFX file..."
if (-not (Test-Path $PfxPath)) {
  Write-Host "[ERROR] PFX file not found: $PfxPath" -ForegroundColor Red
  Write-Host "Expected location: $PfxPath"
  Write-Host ""
  Write-Host "Files in current directory:"
  Get-ChildItem -Filter "*.pfx"
  exit 1
}
Write-Host "[OK] PFX found at $PfxPath" -ForegroundColor Green
$fileSize = (Get-Item $PfxPath).Length / 1KB
Write-Host "     Size: $($fileSize.ToString('F2')) KB" -ForegroundColor Green
Write-Host ""

# Step 3: Test Key Vault connectivity
Write-Host "3. Testing Key Vault connectivity..."
$kvTest = az keyvault show --name $KeyVaultName 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Cannot reach Key Vault '$KeyVaultName'" -ForegroundColor Red
  Write-Host $kvTest
  exit 1
}
Write-Host "[OK] Key Vault is accessible" -ForegroundColor Green
Write-Host ""

# Step 4: Import certificate
Write-Host "4. Importing certificate to Key Vault..."
Write-Host "   Name: $CertificateName"
Write-Host "   Vault: $KeyVaultName"
Write-Host ""

$importResult = az keyvault certificate import `
  --vault-name $KeyVaultName `
  --name $CertificateName `
  --file $PfxPath `
  --password $PfxPassword 2>&1

if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to import certificate" -ForegroundColor Red
  Write-Host $importResult
  exit 1
}

Write-Host "[OK] Certificate imported successfully" -ForegroundColor Green
Write-Host ""

# Step 5: Display certificate details
Write-Host "5. Certificate details:" -ForegroundColor Cyan
$certDetails = $importResult | ConvertFrom-Json
Write-Host ""
Write-Host "   Name:        $($certDetails.name)"
Write-Host "   Thumbprint:  $($certDetails.properties.x509ThumbprintHex)"
Write-Host "   Created:     $(([DateTime]::UnixEpoch.AddSeconds($certDetails.attributes.created)).ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "   Expires:     $(([DateTime]::UnixEpoch.AddSeconds($certDetails.attributes.expires)).ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host ""

# Step 6: Generate secret URI for next step
$secretId = "https://$KeyVaultName.vault.azure.net/secrets/$CertificateName"
Write-Host "6. Secret URI for Application Gateway configuration:" -ForegroundColor Cyan
Write-Host ""
Write-Host "   $secretId" -ForegroundColor Yellow
Write-Host ""
Write-Host "   Save this value for step 5 of the runbook!"
Write-Host ""

Write-Host "✓ Certificate import completed successfully" -ForegroundColor Green
