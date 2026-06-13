# Daily Cloud Photo — Azure Backend

> Requires an Azure account ([create free](https://azure.microsoft.com/free/))

## One-Click Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdaily-cloud-app%2Fphoto%2Fmain%2Fazure%2Fazuredeploy.json)

---

## Quick Deploy

1. Click the **Deploy to Azure** button above
2. Fill in parameters (defaults work fine) → **Review + create** → **Create**
3. After deployment (~3-5 min), go to **Outputs** tab → copy the `functionAppName`
4. Deploy the function code:
   ```bash
   cd function_app
   func azure functionapp publish <functionAppName> --python
   ```
5. Copy the `apiEndpoint` from the Outputs tab
6. In the app: Drawer → Settings → paste the endpoint URL → Save

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

7. Run **Connection Test**
8. Drawer → **Login** → Create account

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
