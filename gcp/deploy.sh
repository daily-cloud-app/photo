#!/bin/bash
# ============================================================
# Daily Cloud Photo — GCP One-Command Deployment (Terraform wrapper)
#
# Preserves the "Open in Cloud Shell → ./deploy.sh → done" experience
# while managing all infrastructure with Terraform.
#
# Steps:
#   1. Validate prerequisites (gcloud, terraform, project)
#   2. Enable minimal bootstrap APIs
#   3. Create/reuse a GCS bucket for remote Terraform state
#   4. terraform init (remote backend) / plan / apply
#   5. Print the API endpoint and connection info
# ============================================================
set -euo pipefail

# ── Configuration (overridable via environment variables) ──
PROJECT_ID="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${GCP_REGION:-asia-northeast1}"
BUCKET_NAME="${PHOTOS_BUCKET:-}"

REQUIRE_EMAIL="${REQUIRE_EMAIL:-true}"
REQUIRE_PHONE="${REQUIRE_PHONE:-false}"
ENABLE_SHARE_URL="${ENABLE_SHARE_URL:-true}"
ENABLE_SHARE_DOWNLOAD_URL="${ENABLE_SHARE_DOWNLOAD_URL:-true}"
ENABLE_LABEL_SHARING="${ENABLE_LABEL_SHARING:-true}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Daily Cloud Photo Backend}"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Daily Cloud Photo - GCP Deployment (Terraform)${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ── [1/5] Prerequisites ──
echo -e "${YELLOW}[1/5] Checking prerequisites...${NC}"

if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}ERROR: gcloud CLI is not installed.${NC}"
    echo "Install from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

if ! command -v terraform &> /dev/null; then
    echo -e "${RED}ERROR: terraform is not installed.${NC}"
    echo "Cloud Shell includes Terraform by default. Otherwise install from:"
    echo "  https://developer.hashicorp.com/terraform/downloads"
    exit 1
fi

if [ -z "${PROJECT_ID}" ]; then
    echo -e "${RED}ERROR: No GCP project configured.${NC}"
    echo "Run: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

BUCKET_NAME="${BUCKET_NAME:-${PROJECT_ID}-photos}"
STATE_BUCKET="${PROJECT_ID}-tfstate"

echo -e "  Project: ${GREEN}${PROJECT_ID}${NC}"
echo -e "  Region:  ${GREEN}${REGION}${NC}"
echo -e "  Bucket:  ${GREEN}${BUCKET_NAME}${NC}"
echo -e "  State:   ${GREEN}gs://${STATE_BUCKET}${NC}"
echo ""

# ── [2/5] Bootstrap APIs (minimum needed before Terraform runs) ──
echo -e "${YELLOW}[2/5] Enabling bootstrap APIs...${NC}"
gcloud services enable \
    serviceusage.googleapis.com \
    cloudresourcemanager.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}" \
    --quiet
echo -e "  ${GREEN}OK APIs enabled${NC}"
echo ""

# ── [3/5] Remote state bucket (bootstrap) ──
echo -e "${YELLOW}[3/5] Preparing Terraform state bucket...${NC}"
if gsutil ls -b "gs://${STATE_BUCKET}" &> /dev/null; then
    echo -e "  ${GREEN}OK State bucket already exists${NC}"
else
    gsutil mb -l "${REGION}" -p "${PROJECT_ID}" "gs://${STATE_BUCKET}"
    echo -e "  ${GREEN}OK State bucket created${NC}"
fi
# Enable versioning on state bucket for safety; keep it private (default).
gsutil versioning set on "gs://${STATE_BUCKET}" > /dev/null 2>&1 || true
echo ""

# ── [4/5] Terraform ──
echo -e "${YELLOW}[4/5] Running Terraform...${NC}"
cd "${TF_DIR}"

terraform init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}"

terraform apply -input=false -auto-approve \
    -var="project_id=${PROJECT_ID}" \
    -var="region=${REGION}" \
    -var="bucket_name=${BUCKET_NAME}" \
    -var="require_email=${REQUIRE_EMAIL}" \
    -var="require_phone=${REQUIRE_PHONE}" \
    -var="enable_share_url=${ENABLE_SHARE_URL}" \
    -var="enable_share_download_url=${ENABLE_SHARE_DOWNLOAD_URL}" \
    -var="enable_label_sharing=${ENABLE_LABEL_SHARING}" \
    -var="app_display_name=${APP_DISPLAY_NAME}"
echo ""

# ── [5/5] Summary ──
API_URL="$(terraform output -raw api_endpoint 2>/dev/null || echo '')"

echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "  Project:      ${GREEN}${PROJECT_ID}${NC}"
echo -e "  Region:       ${GREEN}${REGION}${NC}"
echo -e "  Photos Bucket:${GREEN} ${BUCKET_NAME}${NC}"
echo -e "  API Endpoint: ${GREEN}${API_URL}${NC}"
echo ""
echo -e "  Test with:"
echo -e "    curl ${API_URL}/info"
echo ""
echo -e "  Configure the app:"
echo -e "    Open Drawer -> Settings -> Enter endpoint URL -> Save"
echo ""
echo -e "${BLUE}============================================================${NC}"
