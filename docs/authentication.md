# Configure user authentication with Microsoft Entra ID

Live Voice Practice can run with or without user sign-in.

- Without authentication, users can practice and run analysis, but the app cannot safely show persistent **Past Practices** because there is no trusted user identity.
- With Microsoft Entra ID authentication enabled, the app receives Container Apps authentication headers, associates conversations with the signed-in user, and shows **Past Practices** for that user. Trainers can also see broader practice history when their role is configured.

The application expects Azure Container Apps built-in authentication, sometimes called Easy Auth. The backend reads the `x-ms-client-principal` headers injected by the platform; the frontend only calls `/api/me` to decide whether to show authenticated features.

## Prerequisites

- Azure CLI and Azure Developer CLI installed.
- The app already deployed with `azd up` or `azd deploy`.
- Permission to create or update Microsoft Entra app registrations.
- The public app hostname you want users to open, for example `https://<your-hostname>`.

Run the commands below from your workstation with the correct `azd` environment selected. You do not need to run them from the jumpbox.

## 1. Find the deployed Container App

Run this from the workstation where your `azd` environment is selected:

```bash
RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP)
CONTAINER_APP_NAME=$(az containerapp list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?tags.\"azd-service-name\" == 'voicelab'].name | [0]" \
  --output tsv)

echo "$RESOURCE_GROUP"
echo "$CONTAINER_APP_NAME"
```

## 2. Create the Entra app registration

Use a web app registration. The redirect URI must use the public hostname that users will access and the built-in authentication callback path:

```bash
APP_HOSTNAME="https://<your-hostname>"
APP_NAME="Live Voice Practice"

APP_ID=$(az ad app create \
  --display-name "$APP_NAME" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "$APP_HOSTNAME/.auth/login/aad/callback" \
  --query appId \
  --output tsv)

TENANT_ID=$(az account show --query tenantId --output tsv)

echo "Application (client) ID: $APP_ID"
echo "Tenant ID: $TENANT_ID"
```

Enable ID tokens for Container Apps authentication and create the service principal:

```bash
az ad app update \
  --id "$APP_ID" \
  --enable-id-token-issuance true

az ad sp create --id "$APP_ID"
```

If users also access the direct Container App hostname, add that callback too:

```bash
CONTAINER_APP_FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)

az ad app update \
  --id "$APP_ID" \
  --web-redirect-uris \
    "$APP_HOSTNAME/.auth/login/aad/callback" \
    "https://$CONTAINER_APP_FQDN/.auth/login/aad/callback"
```

## 3. Create a client secret

```bash
CLIENT_SECRET=$(az ad app credential reset \
  --id "$APP_ID" \
  --display-name container-app-auth \
  --years 1 \
  --query password \
  --output tsv)
```

Save the secret securely. Azure shows it only once.

## 4. Enable Container Apps authentication

Configure the Microsoft identity provider:

```bash
az containerapp auth microsoft update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --client-id "$APP_ID" \
  --client-secret "$CLIENT_SECRET" \
  --tenant-id "$TENANT_ID" \
  --issuer "https://login.microsoftonline.com/$TENANT_ID/v2.0" \
  --allowed-audiences "$APP_ID" \
  --yes
```

Then enable auth for the app. The recommended default is to allow anonymous traffic so unauthenticated users can still practice, while signed-in users get history:

```bash
az containerapp auth update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --enabled true \
  --unauthenticated-client-action AllowAnonymous \
  --require-https true \
  --proxy-convention Standard \
  --yes
```

Use `AllowAnonymous` when you want optional sign-in. If every user must sign in before using the app, use `RedirectToLoginPage` instead:

```bash
az containerapp auth update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --unauthenticated-client-action RedirectToLoginPage \
  --set globalValidation.redirectToProvider=azureActiveDirectory \
  --yes
```

## 5. Sign in and validate

Open:

```text
https://<your-hostname>/.auth/login/aad
```

After sign-in, validate that the app sees the user:

```bash
curl -s https://<your-hostname>/api/me
```

Expected authenticated shape:

```json
{
  "authenticated": true,
  "user_id": "<entra-user-object-id>",
  "name": "<display-name>",
  "email": "<user-email>",
  "role": "trainee"
}
```

In the UI, authenticated users see **Past Practices**. Anonymous users do not see persistent history.

## Trainer access

By default, authenticated users are trainees. The app stores trainer assignments in the `role_assignments` Cosmos DB container. Add a document for each trainer:

```json
{
  "id": "<entra-user-object-id>",
  "userId": "<entra-user-object-id>",
  "role": "trainer"
}
```

After the trainer signs in again, the UI shows trainer actions such as **All Practices**.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Sign-in fails with a redirect URI error | The Entra app registration must include `https://<your-hostname>/.auth/login/aad/callback`. |
| `/api/me` returns `{"authenticated": false}` after sign-in | Confirm Container Apps auth is enabled and the Microsoft provider is configured on the same Container App serving the backend. |
| Redirects use the Container App hostname instead of the public hostname | Keep `--proxy-convention Standard` enabled and make sure the gateway/proxy forwards `X-Forwarded-Host` and `X-Forwarded-Proto`. |
| Past Practices is not visible | The user must be signed in; anonymous sessions do not have persistent user history. |
| Trainer cannot see All Practices | Add or fix the `role_assignments` document for that user's Entra object ID. |

