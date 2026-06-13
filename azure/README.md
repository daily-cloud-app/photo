# Daily Cloud Photo — Azure Backend

## One-Click Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdaily-cloud-app%2Fphoto%2Fmain%2Fazure%2Fazuredeploy.json)

---

## Prerequisites

- Azure subscription ([free account](https://azure.microsoft.com/free/))
- Azure CLI installed (`az` command) — [Install guide](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- (Optional) Azure Functions Core Tools — [Install guide](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- Python 3.11+ (for local development)

---

## Quick Deploy

### Option A: Azure Portal (One-Click)

1. Click the **Deploy to Azure** button above
2. Fill in parameters (defaults work fine)
3. Click **Review + create** → **Create**
4. After deployment (~3-5 min), go to **Outputs** tab → copy `apiEndpoint`
5. In the app: Drawer → Settings → paste the endpoint URL → Save

### Option B: Azure CLI

```bash
# Login to Azure
az login

# Run the deployment script
chmod +x deploy.sh
./deploy.sh [RESOURCE_GROUP] [LOCATION] [APP_NAME]

# Example:
./deploy.sh daily-cloud-photo-rg eastus dailycloudphoto
```

### Option C: Manual CLI

```bash
# Create resource group
az group create --name daily-cloud-photo-rg --location eastus

# Deploy ARM template
az deployment group create \
  --resource-group daily-cloud-photo-rg \
  --template-file azuredeploy.json \
  --parameters appName=dailycloudphoto

# Get the function app name from outputs
FUNC_APP=$(az deployment group show \
  --resource-group daily-cloud-photo-rg \
  --name azuredeploy \
  --query "properties.outputs.functionAppName.value" -o tsv)

# Deploy function code
cd function_app
func azure functionapp publish $FUNC_APP --python
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `appName` | `dailycloudphoto` | Base name for all resources |
| `location` | Resource group location | Azure region |
| `jwtSecret` | Auto-generated | Secret key for JWT signing |
| `accessTokenExpireMinutes` | `60` | Access token lifetime (minutes) |
| `refreshTokenExpireDays` | `30` | Refresh token lifetime (days) |
| `requireEmail` | `true` | Require email for signup |
| `requirePhone` | `false` | Require phone for signup |
| `enableShareUrl` | `true` | Enable upload URL sharing |
| `enableLabelSharing` | `true` | Enable label sharing between users |

---

## Connecting the App

1. Open Drawer → **Settings** → Enter the API endpoint URL → **Save**
2. Run **Connection Test**
3. Drawer → **Login** → Create account

---

## Architecture

```
                          ┌─────────────────────────────────────────┐
                          │         Azure Function App              │
User ─── HTTPS ──────────▶  (Python 3.11, v2 Programming Model)   │
                          │                                         │
                          │  ┌─────────┐  ┌──────────┐  ┌───────┐ │
                          │  │ Auth    │  │ Photos   │  │ Share │ │
                          │  │ (JWT)   │  │ CRUD     │  │ APIs  │ │
                          │  └────┬────┘  └────┬─────┘  └───┬───┘ │
                          └───────┼────────────┼─────────────┼─────┘
                                  │            │             │
                    ┌─────────────┼────────────┼─────────────┼─────┐
                    │             ▼            ▼             ▼     │
                    │  ┌──────────────┐  ┌──────────────────────┐  │
                    │  │  Cosmos DB   │  │  Azure Blob Storage  │  │
                    │  │  (Serverless)│  │  (Photos + Thumbs)   │  │
                    │  │              │  │                      │  │
                    │  │  • users     │  │  • users/{uid}/...   │  │
                    │  │  • photos    │  │  • thumbnails/...    │  │
                    │  └──────────────┘  └───────────┬──────────┘  │
                    │                                │              │
                    │                    ┌───────────▼──────────┐   │
                    │                    │  Blob Trigger        │   │
                    │                    │  (EXIF + Thumbnail)  │   │
                    │                    └──────────────────────┘   │
                    └──────────────────────────────────────────────┘
```

### Components

| Component | Azure Service | Equivalent (AWS/GCP) |
|-----------|--------------|---------------------|
| API & Logic | Azure Functions (Python) | Lambda / Cloud Functions |
| Database | Cosmos DB (NoSQL, Serverless) | DynamoDB / Firestore |
| File Storage | Azure Blob Storage | S3 / Cloud Storage |
| Auth | Custom JWT (PyJWT + bcrypt) | Cognito / Firebase Auth |
| Monitoring | Application Insights | CloudWatch / Cloud Logging |
| IaC | ARM Template | CloudFormation / — |

### Auth Design

This implementation uses **self-contained JWT auth** (no external auth provider):
- Users stored in Cosmos DB with bcrypt-hashed passwords
- Access tokens: short-lived JWTs (default 60 min)
- Refresh tokens: longer-lived JWTs (default 30 days)
- No external dependency (Azure AD B2C, Firebase, etc.)
- Password reset via server-generated codes (logged for self-hosted setups)

---

## Local Development

```bash
cd function_app

# Create virtual environment
python -m venv .venv
source .venv/bin/activate  # Linux/Mac
# .venv\Scripts\activate   # Windows

# Install dependencies
pip install -r requirements.txt

# Create local.settings.json
cat > local.settings.json << 'EOF'
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "COSMOS_CONNECTION": "<your-cosmos-connection-string>",
    "COSMOS_DATABASE": "dailycloudphoto",
    "STORAGE_CONNECTION": "<your-storage-connection-string>",
    "STORAGE_CONTAINER": "photos",
    "JWT_SECRET": "dev-secret-change-me",
    "REQUIRE_EMAIL": "true",
    "ENABLE_SHARE_URL": "true",
    "ENABLE_LABEL_SHARING": "true"
  }
}
EOF

# Run locally
func start
```

---

## Deleting Resources

```bash
# Delete all resources in the resource group
az group delete --name daily-cloud-photo-rg --yes --no-wait
```

> This permanently deletes all data (photos, users, metadata).

---

## Cost Estimate

All services use **serverless/consumption** pricing. Low usage is extremely cheap.

These are estimates only. Actual costs depend on usage patterns and may vary. Always monitor your cloud provider's billing dashboard.

| Service | Pricing Model | Free Tier / Estimate |
|---------|--------------|---------------------|
| Azure Functions | Consumption plan | 1M executions/month free |
| Cosmos DB | Serverless (per-RU) | First 1000 RU/s free tier available |
| Blob Storage | Pay-per-GB | ~$0.02/GB/month (Hot tier) |
| Application Insights | Per-GB ingestion | 5 GB/month free |

**Estimated monthly cost for personal use (< 1000 photos):** $1–5/month

---

## Security Recommendations

The template includes basic security (HTTPS-only, no public blob access, TLS 1.2).
For production use, also consider:

- **JWT Secret rotation**: Periodically rotate the JWT_SECRET app setting
- **Network restrictions**: Use Azure Private Endpoints for Cosmos DB
- **WAF**: Place Azure Front Door with WAF in front of the Function App
- **CORS restriction**: Limit allowed origins to your app's domain
- **Rate limiting**: Configure Azure API Management or custom middleware
- **Key Vault**: Store secrets in Azure Key Vault instead of app settings
- **Managed Identity**: Use system-assigned managed identity for Cosmos DB access
- **Backup**: Enable Cosmos DB continuous backup

---

## API Reference

See [API.md](../aws/API.md) for the complete API specification.
All endpoints from the spec are implemented in this Azure backend.

## Troubleshooting

### Function app returns 404
- Ensure the route prefix is `v1` in `host.json`
- Check that deployment completed: `az functionapp show --name <app> --resource-group <rg>`

### Connection timeout to Cosmos DB
- Verify the `COSMOS_CONNECTION` app setting is correct
- Check if the Cosmos DB account is in the same region

### Upload fails (SAS token error)
- Verify CORS is configured on the storage account
- Check that `STORAGE_CONNECTION` has the correct account key
- Ensure the `photos` container exists

### Logs
```bash
# Stream live logs
az functionapp log tail --name <function-app-name> --resource-group <rg>

# Check Application Insights
az monitor app-insights query --app <insights-name> --analytics-query "traces | order by timestamp desc | take 50"
```
