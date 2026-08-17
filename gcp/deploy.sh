#!/bin/bash
# ============================================================
# Daily Cloud Photo — GCP One-Command Deployment (Terraform wrapper)
#
# Preserves the "Open in Cloud Shell → ./deploy.sh → done" experience
# while managing all infrastructure with Terraform.
#
# Steps:
#   1. Validate prerequisites (gcloud, project)
#   2. Ensure a REAL Terraform CLI is available (auto-install if needed)
#   3. Enable minimal bootstrap APIs
#   4. Create/reuse a GCS bucket for remote Terraform state
#   5. terraform init (remote backend) / apply
#   6. Print the API endpoint and connection info
#
# Notes:
#   - As of mid-2026, Cloud Shell no longer bundles Terraform; `terraform`
#     is a stub that only prints install instructions. This script detects
#     that case and installs a real Terraform CLI into $HOME/.local/bin
#     (which persists across Cloud Shell sessions).
#   - "Deployment Complete!" is printed ONLY when terraform apply succeeded
#     AND a non-empty API endpoint was produced.
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

# Terraform CLI settings
TF_VERSION="${TF_VERSION:-1.9.8}"
LOCAL_BIN="${HOME}/.local/bin"

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

# ============================================================
# Terraform CLI detection / installation helpers
# ============================================================

# Returns 0 only if the given command is a genuine Terraform CLI.
# The Cloud Shell stub prints install instructions instead of a real
# version banner, so we require the output to start with "Terraform v".
is_real_terraform() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || return 1
    local first_line
    first_line="$("$cmd" version 2>/dev/null | head -n1 || true)"
    case "$first_line" in
        Terraform\ v*) return 0 ;;
        *) return 1 ;;
    esac
}

install_terraform() {
    local arch url tmp
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            echo -e "${RED}ERROR: Unsupported architecture: $(uname -m)${NC}"
            exit 1
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}ERROR: curl is required to install Terraform.${NC}"
        exit 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "${RED}ERROR: unzip is required to install Terraform.${NC}"
        exit 1
    fi

    url="https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${arch}.zip"
    tmp="$(mktemp -d)"

    echo -e "  Downloading Terraform ${TF_VERSION} (${arch})..."
    if ! curl -fsSL "$url" -o "${tmp}/terraform.zip"; then
        echo -e "${RED}ERROR: Failed to download Terraform from ${url}${NC}"
        rm -rf "$tmp"
        exit 1
    fi

    mkdir -p "$LOCAL_BIN"
    unzip -o -q "${tmp}/terraform.zip" -d "$LOCAL_BIN"
    chmod +x "${LOCAL_BIN}/terraform"
    rm -rf "$tmp"
}

# ── [1/6] Prerequisites ──
echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"

if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}ERROR: gcloud CLI is not installed.${NC}"
    echo "Install from: https://cloud.google.com/sdk/docs/install"
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

# ── [2/6] Ensure a real Terraform CLI ──
echo -e "${YELLOW}[2/6] Ensuring Terraform CLI...${NC}"
export PATH="${LOCAL_BIN}:${PATH}"
TF=""

if is_real_terraform "${LOCAL_BIN}/terraform"; then
    TF="${LOCAL_BIN}/terraform"
elif is_real_terraform "terraform"; then
    TF="$(command -v terraform)"
else
    echo -e "  ${YELLOW}Real Terraform CLI not found (Cloud Shell ships a stub). Installing...${NC}"
    install_terraform
    if is_real_terraform "${LOCAL_BIN}/terraform"; then
        TF="${LOCAL_BIN}/terraform"
    else
        echo -e "${RED}ERROR: Terraform installation failed or produced a non-working binary.${NC}"
        exit 1
    fi
fi

echo -e "  ${GREEN}Using Terraform: ${TF}${NC}"
echo -e "  $("$TF" version | head -n1)"
echo ""

# ── [3/6] Bootstrap APIs (minimum needed before Terraform runs) ──
echo -e "${YELLOW}[3/6] Enabling bootstrap APIs...${NC}"
gcloud services enable \
    serviceusage.googleapis.com \
    cloudresourcemanager.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}" \
    --quiet
echo -e "  ${GREEN}OK APIs enabled${NC}"
echo ""

# ── [4/6] Remote state bucket (bootstrap) ──
echo -e "${YELLOW}[4/6] Preparing Terraform state bucket...${NC}"
if gsutil ls -b "gs://${STATE_BUCKET}" &> /dev/null; then
    echo -e "  ${GREEN}OK State bucket already exists${NC}"
else
    gsutil mb -l "${REGION}" -p "${PROJECT_ID}" "gs://${STATE_BUCKET}"
    echo -e "  ${GREEN}OK State bucket created${NC}"
fi
# Enable versioning on state bucket for safety; keep it private (default).
gsutil versioning set on "gs://${STATE_BUCKET}" > /dev/null 2>&1 || true
echo ""

# ── [5/6] Terraform ──
echo -e "${YELLOW}[5/6] Running Terraform...${NC}"
cd "${TF_DIR}"

"$TF" init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}"

"$TF" apply -input=false -auto-approve \
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

# ── [6/6] Summary ──
# Only treat the deployment as successful when a non-empty API endpoint
# was produced by Terraform. An empty value means apply did not create
# the function (or was a no-op), so we must NOT report success.
API_URL="$("$TF" output -raw api_endpoint 2>/dev/null || true)"

if [ -z "${API_URL}" ]; then
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}  Deployment FAILED${NC}"
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}  Terraform did not produce an API endpoint.${NC}"
    echo -e "${RED}  Check the Terraform output above for errors.${NC}"
    exit 1
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "  Project:       ${GREEN}${PROJECT_ID}${NC}"
echo -e "  Region:        ${GREEN}${REGION}${NC}"
echo -e "  Photos Bucket: ${GREEN}${BUCKET_NAME}${NC}"
echo -e "  API Endpoint:  ${GREEN}${API_URL}${NC}"
echo ""
echo -e "  Test with:"
echo -e "    curl ${API_URL}/info"
echo ""
echo -e "  Configure the app:"
echo -e "    Open Drawer -> Settings -> Enter endpoint URL -> Save"
echo ""
echo -e "${BLUE}============================================================${NC}"
