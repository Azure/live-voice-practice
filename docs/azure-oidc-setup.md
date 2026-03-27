# Configuração de OIDC para GitHub Actions com Azure

Este documento explica como configurar a autenticação OIDC (OpenID Connect) entre GitHub Actions e Azure, eliminando a necessidade de secrets para credenciais.

## 🔐 Por que usar OIDC?

| Método | Segurança | Manutenção |
|--------|-----------|------------|
| **Client Secret** | ⚠️ Pode vazar, precisa rotacionar | Expiram, precisam ser atualizados |
| **OIDC** | ✅ Sem secrets armazenados | Zero manutenção |

## 📋 Pré-requisitos

- Uma subscription Azure ativa
- Permissões para criar App Registrations no Azure AD
- Acesso de admin ao repositório GitHub

## 🚀 Configuração Passo a Passo

### 1. Criar um App Registration no Azure

```bash
# Usando Azure CLI
az ad app create --display-name "github-live-voice-practice"

# Anote o Application (client) ID retornado
```

### 2. Criar Federated Credential para GitHub

No Portal Azure:
1. Vá para **Azure Active Directory** > **App registrations**
2. Selecione o app criado
3. Vá para **Certificates & secrets** > **Federated credentials**
4. Clique em **Add credential**
5. Selecione **GitHub Actions deploying Azure resources**
6. Preencha:
   - **Organization**: `Azure`
   - **Repository**: `live-voice-practice`
   - **Entity type**: `Branch`
   - **Branch**: `main`
   - **Name**: `github-actions-main`

Ou via CLI:

```bash
# Obtenha o Object ID do App Registration
APP_OBJECT_ID=$(az ad app show --id <APPLICATION_ID> --query id -o tsv)

# Crie a credencial federada
az ad app federated-credential create --id $APP_OBJECT_ID --parameters '{
    "name": "github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:Azure/live-voice-practice:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
}'
```

### 3. Criar Service Principal e atribuir Role

```bash
# Criar Service Principal
az ad sp create --id <APPLICATION_ID>

# Atribuir role de Contributor na subscription (ou resource group específico)
az role assignment create \
  --assignee <APPLICATION_ID> \
  --role "Contributor" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>"
```

### 4. Configurar Repository Variables no GitHub

Vá para **Settings** > **Secrets and variables** > **Actions** > **Variables**

Adicione as seguintes **variables** (não secrets!):

| Variable Name | Valor |
|---------------|-------|
| `AZURE_CLIENT_ID` | Application (client) ID do App Registration |
| `AZURE_TENANT_ID` | Directory (tenant) ID do Azure AD |
| `AZURE_SUBSCRIPTION_ID` | ID da sua Azure subscription |
| `AZURE_LOCATION` | Região do Azure (ex: `eastus`) |

## ✅ Verificação

Após configurar, o workflow `deploy-azure.yml` pode ser executado manualmente:

1. Vá para **Actions** > **deploy**
2. Clique em **Run workflow**
3. Selecione o environment desejado
4. Clique em **Run workflow**

## 🔧 Troubleshooting

### Erro: "AADSTS70021: No matching federated identity record found"

- Verifique se o `subject` claim está correto
- Para branches: `repo:Azure/live-voice-practice:ref:refs/heads/main`
- Para environments: `repo:Azure/live-voice-practice:environment:production`

### Erro: "AADSTS700024: Client assertion is not within its valid time range"

- Verifique se o relógio do runner está sincronizado
- Tente executar novamente o workflow

### Erro: "Authorization failed"

- Verifique se o Service Principal tem as roles necessárias
- Confirme que a subscription ID está correta

## 📚 Referências

- [Azure OIDC documentation](https://learn.microsoft.com/en-us/azure/active-directory/workload-identities/workload-identity-federation)
- [GitHub OIDC documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
