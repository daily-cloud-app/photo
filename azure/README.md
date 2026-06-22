# Daily Cloud Photo — Azure Backend

> Requires an Azure account ([create free](https://azure.microsoft.com/free/))

## One-Click Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdaily-cloud-app%2Fphoto%2Fmain%2Fazure%2Fazuredeploy.json)

### Quick Start

1. Click the **Deploy to Azure** button above
2. Fill in parameters (defaults work fine) → **Review + create** → **Create**
3. After deployment (~3-5 min), go to **Outputs** tab → copy `functionAppName`
4. Deploy the function code:
   ```bash
   cd function_app
   func azure functionapp publish <functionAppName> --python
   ```
5. Copy `apiEndpoint` from the Outputs tab into the app

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| appName | `dailycloudphoto` | Base name for all resources |
| location | Resource group location | Azure region |
| jwtSecret | Auto-generated | Secret key for JWT signing |
| accessTokenExpireMinutes | `60` | Access token lifetime (minutes) |
| refreshTokenExpireDays | `30` | Refresh token lifetime (days) |
| requireEmail | `true` | Require email for signup |
| requirePhone | `false` | Require phone number for signup |
| enableShareUrl | `true` | Enable upload URL sharing feature |
| enableLabelSharing | `true` | Enable label sharing between users |
| appDisplayName | `Daily Cloud Photo Backend` | Display name shown in the app |

## Connecting the App

1. Open Drawer → **Settings** → Enter the endpoint URL → **Save**
2. Run **Connection Test**
3. Drawer → **Login** → Create account

## Deleting Resources

```bash
az group delete --name daily-cloud-photo-rg --yes --no-wait
```

> This permanently deletes all data (photos, users, metadata).

## Architecture

```
User → Azure Functions (HTTP) → Main Handler (route dispatch)
                                    ├── Custom JWT Auth (bcrypt + PyJWT)
                                    ├── Blob Storage (photo storage + thumbnails)
                                    ├── Cosmos DB (metadata)
                                    └── Blob Trigger Function (EXIF + thumbnail generation)
```

- Single Function App handles all API routes (path-based routing)
- User photos isolated under `users/{uid}/` prefix
- Direct upload to Blob Storage via SAS URLs (no function proxy)
- Blob trigger automatically extracts EXIF date + generates thumbnails

## Cost Estimate

All services use serverless/consumption pricing. Low usage is extremely cheap.

These are estimates only. Actual costs depend on usage patterns and may vary. Always monitor your cloud provider's billing dashboard.

| Service | Free Tier |
|---------|-----------|
| Azure Functions | 1M executions/month |
| Cosmos DB | First 1000 RU/s free tier available |
| Blob Storage | ~$0.02/GB/month (Hot tier) |
| Application Insights | 5 GB/month |

**Estimated monthly cost for personal use (< 1000 photos):** $1–5/month

## Security Recommendations for Production

The template includes basic security (HTTPS-only, no public blob access, TLS 1.2).
For production use, also consider:

- **JWT Secret rotation**: Periodically rotate the JWT_SECRET app setting
- **Network restrictions**: Use Azure Private Endpoints for Cosmos DB
- **WAF**: Place Azure Front Door with WAF in front of the Function App
- **CORS restriction**: Limit allowed origins to specific domains
- **Rate limiting**: Configure Azure API Management or custom middleware
- **Key Vault**: Store secrets in Azure Key Vault instead of app settings
- **Share URL limits**: Consider adding file size limits, upload count limits, and Content-Type validation
