# Daily Cloud Photo — GCP Backend

## One-Click Deploy

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/daily-cloud-app/photo&cloudshell_working_dir=gcp&cloudshell_tutorial=README.md&cloudshell_open_in_editor=main.py)

---

## Prerequisites

1. **Google Cloud SDK** (`gcloud`) installed and authenticated
2. A GCP project with billing enabled
3. Enable required APIs:
   ```bash
   gcloud services enable \
     cloudfunctions.googleapis.com \
     cloudbuild.googleapis.com \
     firestore.googleapis.com \
     storage.googleapis.com \
     identitytoolkit.googleapis.com \
     run.googleapis.com
   ```
4. **Firebase project** linked to the same GCP project (for Firebase Auth)
5. **Firestore** initialized in Native mode:
   ```bash
   gcloud firestore databases create --location=asia-northeast1
   ```

---

## Quick Deploy

### Option A: One-command deploy script

```bash
chmod +x deploy.sh
./deploy.sh
```

### Option B: Manual steps

```bash
# Set variables
export PROJECT_ID=$(gcloud config get-value project)
export REGION=asia-northeast1
export BUCKET_NAME=${PROJECT_ID}-photos

# Create Cloud Storage bucket
gsutil mb -l ${REGION} gs://${BUCKET_NAME}
gsutil versioning set on gs://${BUCKET_NAME}

# Deploy main API function
gcloud functions deploy daily-cloud-photo-api \
  --gen2 \
  --runtime=python312 \
  --region=${REGION} \
  --source=. \
  --entry-point=main_handler \
  --trigger-http \
  --allow-unauthenticated \
  --memory=256MB \
  --timeout=60s \
  --set-env-vars="PHOTOS_BUCKET=${BUCKET_NAME},GCP_PROJECT=${PROJECT_ID},REQUIRE_EMAIL=true,REQUIRE_PHONE=false,ENABLE_SHARE_URL=true,ENABLE_LABEL_SHARING=true"

# Deploy storage trigger function
gcloud functions deploy daily-cloud-photo-storage-trigger \
  --gen2 \
  --runtime=python312 \
  --region=${REGION} \
  --source=. \
  --entry-point=storage_trigger_handler \
  --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
  --trigger-event-filters="bucket=${BUCKET_NAME}" \
  --memory=512MB \
  --timeout=120s \
  --set-env-vars="PHOTOS_BUCKET=${BUCKET_NAME},GCP_PROJECT=${PROJECT_ID}"
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PROJECT_ID` | (current project) | GCP project ID |
| `REGION` | `asia-northeast1` | Deployment region |
| `BUCKET_NAME` | `{project}-photos` | Cloud Storage bucket for photos |
| `REQUIRE_EMAIL` | `true` | Require email for signup |
| `REQUIRE_PHONE` | `false` | Require phone for signup |
| `ENABLE_SHARE_URL` | `true` | Enable upload URL sharing feature |
| `ENABLE_LABEL_SHARING` | `true` | Enable label sharing between users |

---

## Connecting the App

1. After deployment, copy the function URL from the output:
   ```
   https://{REGION}-{PROJECT_ID}.cloudfunctions.net/daily-cloud-photo-api
   ```
2. Open Drawer → **Settings** → Enter the endpoint URL → **Save**
3. Run **Connection Test**
4. Drawer → **Login** → Create account

---

## Architecture

```
User → Cloud Functions (HTTP) → Main Handler (Flask routing)
                                    ├── Firebase Auth (user management)
                                    ├── Cloud Storage (photo storage + thumbnails)
                                    ├── Firestore (metadata)
                                    └── Storage Trigger Function (EXIF + thumbnail)
```

- Single Cloud Function handles all API routes (Flask-based path routing)
- User photos isolated under `users/{firebase_uid}/` prefix
- Direct upload to Cloud Storage via signed URLs (no function proxy)
- Storage trigger automatically extracts EXIF date + generates thumbnails

---

## Firestore Data Model

```
Collection: photos
  Document ID: {userId}_{photoId}
  Fields:
    - userId: string
    - photoId: string
    - filename: string
    - contentType: string
    - gcsKey: string
    - size: number
    - status: string (uploading | uploaded | deleted)
    - createdAt: string (ISO 8601)
    - labels: array of strings
    - thumbnailKey: string (optional)
    - deletedAt: string (optional)

  Special document types (same collection):
    - share_token:{token} — share upload tokens
    - share:{shareId} — received shares
    - sent_share:{shareId} — sent shares
```

---

## Deleting All Resources

```bash
# Delete functions
gcloud functions delete daily-cloud-photo-api --region=${REGION} --gen2 -q
gcloud functions delete daily-cloud-photo-storage-trigger --region=${REGION} --gen2 -q

# Delete storage bucket (WARNING: deletes all photos)
gsutil -m rm -r gs://${BUCKET_NAME}
gsutil rb gs://${BUCKET_NAME}

# Delete Firestore data (optional)
gcloud firestore databases delete --database="(default)"
```

---

## Cost Estimate

All services are pay-per-use. Low usage typically falls within GCP Free Tier.

These are estimates only. Actual costs depend on usage patterns and may vary. Always monitor your cloud provider's billing dashboard.

| Service | Free Tier |
|---------|-----------|
| Cloud Functions | 2M invocations/month |
| Firestore | 1 GiB storage, 50K reads/day, 20K writes/day |
| Cloud Storage | 5 GB (Standard), 5K Class A ops/month |
| Firebase Auth | 50K MAU (phone auth: 10K verifications/month) |
| Networking | 1 GB egress/month |

---

## Security Recommendations for Production

- **IAM**: Use service accounts with least-privilege roles
- **VPC Connector**: Place functions behind a VPC for internal-only access
- **Cloud Armor**: Add WAF rules in front of Cloud Load Balancer
- **CORS**: Restrict allowed origins in production
- **Audit Logging**: Enable Cloud Audit Logs for all API calls
- **Rate Limiting**: Configure Cloud Functions concurrency limits
- **Share URL limits**: Add file size limits and Content-Type validation
