# Daily Cloud Photo — AWS Backend

> Requires an AWS account ([create free](https://aws.amazon.com/free/))

## One-Click Deploy

Leave `LambdaCodeBucket` empty and the template will automatically download code from GitHub Releases.

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home#/stacks/new?stackName=daily-cloud-photo&templateURL=https://raw.githubusercontent.com/daily-cloud-app/photo/main/aws/template.yaml)

### Quick Start

1. AWS Console → **CloudFormation** → **Create stack**
2. Upload `template.yaml`
3. Parameters:
   - `LambdaCodeBucket`: **Leave empty** (auto-downloads from GitHub)
   - Other parameters: defaults are fine
4. Check "I acknowledge that AWS CloudFormation might create IAM resources"
5. Click **Create stack**
6. After completion, go to **Outputs** tab → copy `ApiEndpoint` URL into the app

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| AppName | `daily-cloud-photo` | Prefix for all resource names |
| RequireEmail | `true` | Require email for signup |
| RequirePhone | `false` | Require phone number for signup |
| PhotosBucketName | (auto-generated) | S3 bucket name for photos |
| LambdaCodeBucket | (empty) | Empty = auto-download from GitHub / Set = manual upload |
| LambdaCodeKey | `daily-cloud-photo/lambda.zip` | S3 key for Lambda ZIP |
| GitHubReleaseUrl | (latest release) | URL to download Lambda ZIP |
| EnableShareUrl | `true` | Enable upload URL sharing feature |
| EnableLabelSharing | `true` | Enable label sharing between users |

## Connecting the App

1. Open Drawer → **Settings** → Enter the endpoint URL → **Save**
2. Run **Connection Test**
3. Drawer → **Login** → Create account

## Deleting the Stack

1. Empty the **S3 bucket** (photos) including versioned objects
2. **CloudFormation** → Stack → **Delete**

## Architecture

```
User → API Gateway (HTTP API) → Lambda (unified handler)
                                    ├── Cognito (auth)
                                    ├── S3 (photo storage + thumbnails)
                                    ├── DynamoDB (metadata)
                                    └── S3 Trigger Lambda (EXIF + thumbnail generation)
```

- Single Lambda handles all API routes (path-based routing)
- User photos isolated under `users/{cognito_sub}/` prefix
- Direct upload to S3 via presigned URLs (no Lambda proxy)
- S3 trigger automatically extracts EXIF date + generates thumbnails

## Cost Estimate

All services are pay-per-use. Low usage typically falls within AWS Free Tier.

These are estimates only. Actual costs depend on usage patterns and may vary. Always monitor your cloud provider's billing dashboard.

| Service | Free Tier |
|---------|-----------|
| Lambda | 1M requests/month |
| API Gateway | 1M requests/month |
| DynamoDB | 25GB + 25 WCU/RCU |
| S3 | 5GB (12 months) |
| Cognito | 50,000 MAU |

## Security Recommendations for Production

The template includes basic security (S3 public access block, token expiration checks).
For production use, also consider:

- **API Gateway throttling**: Add rate limits to prevent brute-force attacks
- **WAF**: Place WAF in front of API Gateway to block malicious requests
- **CORS restriction**: Limit `AllowOrigins` to specific domains
- **CloudTrail**: Enable API call audit logging
- **IAM least privilege**: Remove unnecessary actions (e.g. `Scan`)
- **Share URL limits**: Consider adding file size limits, upload count limits, and Content-Type validation for share upload tokens
