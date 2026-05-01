$ErrorActionPreference = 'Stop'
$rg     = 'rg-paulolacerda-0429235840'
$app    = 'ca-wkclmlic2p3vo-voicelab'
$uaiId  = '/subscriptions/4c7ae2e2-8d3e-4712-9b7d-04ccbdcc7e70/resourcegroups/rg-paulolacerda-0429235840/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ca-wkclmlic2p3vo-voicelab-mi'
$uaiPid = 'dde6b420-6080-4b4d-ab5c-4d032664d388'
$uaiCid = '321c7f58-fb44-488d-b1df-e1939d47b5ae'
$oldPid = '28823312-3631-423a-9287-7ae056a4b289'

Write-Host "=== 1) Replicar roles do System MI -> UAI ==="
$roles = az role assignment list --assignee $oldPid --all --query "[].{role:roleDefinitionName, scope:scope}" -o json | ConvertFrom-Json
foreach ($r in $roles) {
    Write-Host "+ $($r.role) on $($r.scope.Split('/')[-1])"
    az role assignment create --assignee-object-id $uaiPid --assignee-principal-type ServicePrincipal --role "$($r.role)" --scope "$($r.scope)" -o none 2>&1 | Out-Null
}
$count = az role assignment list --assignee $uaiPid --all --query "length(@)" -o tsv
Write-Host "Roles replicadas: $count"

Write-Host "`n=== 2) Anexar UAI ao Container App ==="
az containerapp identity assign -g $rg -n $app --user-assigned $uaiId -o none

Write-Host "`n=== 3) Setar AZURE_CLIENT_ID env var (apontando pra UAI) ==="
az containerapp update -g $rg -n $app --set-env-vars "AZURE_CLIENT_ID=$uaiCid" -o none

Write-Host "`n=== 4) Verificar revisão ativa e env ==="
az containerapp show -g $rg -n $app --query "{rev: properties.latestRevisionName, identityType: identity.type, uais: keys(identity.userAssignedIdentities)}" -o json
az containerapp show -g $rg -n $app --query "properties.template.containers[0].env" -o json

Write-Host "`n=== 5) RBAC for Cosmos DB (data plane) - critical for scenarios ==="
$cosmos = "cosmos-wkclmlic2p3vo"
$cosmosId = az cosmosdb show -g $rg -n $cosmos --query id -o tsv
# Cosmos DB Built-in Data Contributor = 00000000-0000-0000-0000-000000000002
az cosmosdb sql role assignment create --account-name $cosmos -g $rg --role-definition-id "00000000-0000-0000-0000-000000000002" --principal-id $uaiPid --scope $cosmosId -o none 2>&1 | Tee-Object -Variable cosmosRbac
Write-Host "Cosmos role assignment result: $cosmosRbac"

Write-Host "`nFEITO. App vai reiniciar com nova revisao."
