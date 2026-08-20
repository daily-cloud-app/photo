#!/bin/bash
# Daily Cloud Photo — Azure deployment (Bicep + Microsoft Entra External ID)
#
# This script is a thin wrapper around:
#   1. Bicep     — provisions all Azure infrastructure (Flex Consumption).
#   2. Graph API — configures the Entra External ID app registration.
#   3. OneDeploy — publishes the function code to the Flex deployment container.
#
# Authentication is delegated to Microsoft Entra External ID (native
# authentication). This script never creates a JWT secret and never uses the
# legacy "az functionapp deployment source config-zip" content-share flow.
#
# Prerequisites:
#   - Azure CLI (az) logged in:  az login
#   - zip, curl, python3 (pre-installed in Cloud Shell)
#   - An existing Microsoft Entra *external* tenant (see README). Creating an
#     external tenant is not scriptable end-to-end, so its subdomain + id are
#     taken as input; everything after that is automated.
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Configuration is read from environment variables (with sensible defaults):
#   RESOURCE_GROUP        (default: daily-cloud-photo-rg)
#   LOCATION              (default: eastus)  — must be a Flex Consumption region
#   APP_NAME              (default: dailycloudphoto)
#   ENTRA_TENANT_SUBDOMAIN   external tenant subdomain (e.g. "contoso")
#   ENTRA_TENANT_ID          external tenant (directory) GUID
#   ENTRA_CLIENT_ID          (optional) existing app registration to reuse
#   ENTRA_APP_DISPLAY_NAME   (default: "Daily Cloud Photo (native auth)")

set -euo pipefail

# ── Disable interactive extension prompts ──
az config set extension.use_dynamic_install=no_without_prompt >/dev/null 2>&1 || true

# ── Configuration ──
RESOURCE_GROUP="${RESOURCE_GROUP:-daily-cloud-photo-rg}"
LOCATION="${LOCATION:-eastus}"
APP_NAME="${APP_NAME:-dailycloudphoto}"
BICEP_MAIN="./bicep/main.bicep"
FUNCTION_APP_DIR="./function_app"

# Entra External ID inputs.
ENTRA_TENANT_SUBDOMAIN="${ENTRA_TENANT_SUBDOMAIN:-}"
ENTRA_TENANT_ID="${ENTRA_TENANT_ID:-}"
ENTRA_CLIENT_ID="${ENTRA_CLIENT_ID:-}"
ENTRA_APP_DISPLAY_NAME="${ENTRA_APP_DISPLAY_NAME:-Daily Cloud Photo (native auth)}"

echo "=============================================="
echo " Daily Cloud Photo — Azure Deployment (Bicep)"
echo "=============================================="
echo ""
echo " Resource Group: $RESOURCE_GROUP"
echo " Location:       $LOCATION"
echo " App Name:       $APP_NAME"
echo " External tenant: ${ENTRA_TENANT_SUBDOMAIN:-<not set>}"
echo ""

# ============================================================
# Step 1: Prerequisites
# ============================================================
echo "[1/7] Checking prerequisites..."

if ! command -v az &> /dev/null; then
    echo "ERROR: Azure CLI (az) is not installed."
    echo "Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

if ! az account show &> /dev/null; then
    echo "Not logged in to Azure. Running 'az login'..."
    az login
fi

echo "  Logged in as: $(az account show --query user.name -o tsv)"
echo "  Subscription: $(az account show --query name -o tsv)"
echo ""

# ============================================================
# Step 2: Register resource providers
# ============================================================
echo "[2/7] Registering resource providers..."

register_provider() {
    local ns="$1"
    local state
    state=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
    if [ "$state" != "Registered" ]; then
        echo "  Registering $ns ..."
        az provider register --namespace "$ns" --wait 2>/dev/null || true
    fi
}

register_provider "Microsoft.Web"
register_provider "Microsoft.DocumentDB"
register_provider "Microsoft.OperationalInsights"
register_provider "Microsoft.Insights"
register_provider "Microsoft.ManagedIdentity"
register_provider "Microsoft.EventGrid"
echo "  Providers ready."
echo ""

# ============================================================
# Step 3: Configure Entra External ID (Microsoft Graph)
# ============================================================
echo "[3/7] Configuring Microsoft Entra External ID (native authentication)..."

if [ -z "$ENTRA_TENANT_SUBDOMAIN" ] || [ -z "$ENTRA_TENANT_ID" ]; then
    echo "  ERROR: ENTRA_TENANT_SUBDOMAIN and ENTRA_TENANT_ID are required."
    echo ""
    echo "  Creating an external tenant is not fully scriptable. Create one in"
    echo "  the Microsoft Entra admin center (External ID), then re-run with:"
    echo "    export ENTRA_TENANT_SUBDOMAIN=<yourtenant>"
    echo "    export ENTRA_TENANT_ID=<tenant-guid>"
    echo "  See azure/README.md for the full walkthrough."
    exit 1
fi

configure_entra_app() {
    # Acquire a Graph token for the *external* tenant. The signed-in account
    # must be an administrator of that external tenant.
    local graph_token
    graph_token=$(az account get-access-token \
        --tenant "$ENTRA_TENANT_ID" \
        --resource-type ms-graph \
        --query accessToken -o tsv 2>/dev/null || echo "")

    if [ -z "$graph_token" ]; then
        echo "  WARNING: Could not obtain a Graph token for tenant $ENTRA_TENANT_ID."
        echo "  Run 'az login --tenant $ENTRA_TENANT_ID' first, or pass an"
        echo "  existing ENTRA_CLIENT_ID to skip app-registration automation."
        return 1
    fi

    # Reuse an existing app registration if provided.
    if [ -n "$ENTRA_CLIENT_ID" ]; then
        echo "  Using existing app registration: $ENTRA_CLIENT_ID"
        return 0
    fi

    echo "  Creating app registration '$ENTRA_APP_DISPLAY_NAME' ..."
    # Public client + native auth: enable public client flows and the native
    # auth "redirect" reply. isFallbackPublicClient=true marks it public.
    local body
    body=$(python3 - "$ENTRA_APP_DISPLAY_NAME" <<'PY'
import json, sys
print(json.dumps({
    "displayName": sys.argv[1],
    "signInAudience": "AzureADandPersonalMicrosoftAccount",
    "isFallbackPublicClient": True,
    "publicClient": {"redirectUris": ["https://login.microsoftonline.com/common/oauth2/nativeclient"]},
}))
PY
)
    local created
    created=$(curl -s -X POST "https://graph.microsoft.com/v1.0/applications" \
        -H "Authorization: Bearer $graph_token" \
        -H "Content-Type: application/json" \
        -d "$body")

    ENTRA_CLIENT_ID=$(echo "$created" | python3 -c "import sys,json;print(json.load(sys.stdin).get('appId',''))" 2>/dev/null || echo "")

    if [ -z "$ENTRA_CLIENT_ID" ]; then
        echo "  WARNING: App registration failed. Graph response:"
        echo "  $created"
        echo ""
        echo "  Native authentication also requires enabling the native-auth API"
        echo "  and associating a user flow — these steps are portal-driven."
        echo "  Create the app registration + user flow manually (see README),"
        echo "  then re-run with ENTRA_CLIENT_ID set."
        return 1
    fi

    echo "  App registration created. client_id=$ENTRA_CLIENT_ID"
    echo ""
    echo "  NOTE: In the Entra admin center, finish these portal-only steps:"
    echo "    - Enable public client and native authentication flows on the app"
    echo "    - Create an email + password user flow (with email OTP + SSPR)"
    echo "    - Associate this app registration with the user flow"
    return 0
}

configure_entra_app || echo "  Continuing; verify Entra setup before testing auth."

if [ -z "$ENTRA_CLIENT_ID" ]; then
    echo "  ERROR: No ENTRA_CLIENT_ID available. Cannot configure the backend."
    echo "  Set ENTRA_CLIENT_ID and re-run."
    exit 1
fi
echo ""

# ============================================================
# Step 4: Deploy infrastructure with Bicep
# ============================================================
echo "[4/7] Creating resource group and deploying Bicep..."

az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

DEPLOYMENT_OUTPUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$BICEP_MAIN" \
    --parameters \
        appName="$APP_NAME" \
        entraTenantSubdomain="$ENTRA_TENANT_SUBDOMAIN" \
        entraTenantId="$ENTRA_TENANT_ID" \
        entraClientId="$ENTRA_CLIENT_ID" \
    --query properties.outputs \
    --output json)

get_output() {
    echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',{}).get('value',''))" 2>/dev/null || echo ""
}

FUNCTION_APP_NAME=$(get_output functionAppName)
API_ENDPOINT=$(get_output apiEndpoint)
STORAGE_ACCOUNT=$(get_output storageAccountName)

if [ -z "$FUNCTION_APP_NAME" ]; then
    echo "ERROR: Bicep deployment failed. Check the Azure Portal for details."
    exit 1
fi

echo "  Function App: $FUNCTION_APP_NAME"
echo "  API Endpoint: $API_ENDPOINT"
echo "  Storage:      $STORAGE_ACCOUNT"
echo ""

# ============================================================
# Step 5: Deploy function code (Flex Consumption OneDeploy)
# ============================================================
echo "[5/7] Deploying function code (remote build)..."

DEPLOY_ZIP="$(mktemp -d)/app.zip"
(
    cd "$FUNCTION_APP_DIR"
    zip -r "$DEPLOY_ZIP" . -x "__pycache__/*" "*.pyc" ".venv/*" ".git/*" "local.settings.json" >/dev/null
)

# Flex Consumption uses OneDeploy: the package is uploaded to the deployment
# storage container configured in the Bicep functionAppConfig. This is not the
# legacy content-share config-zip flow.
az functionapp deploy \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --src-path "$DEPLOY_ZIP" \
    --type zip \
    --remote-build \
    --output none

rm -f "$DEPLOY_ZIP"
echo "  Code deployed."
echo ""

# ============================================================
# Step 6: Event Grid subscription for the blob (thumbnail) trigger
# ============================================================
echo "[6/7] Wiring Event Grid blob trigger..."

BLOB_KEY=""
for _ in $(seq 1 12); do
    BLOB_KEY=$(az functionapp keys list --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" \
        --query "systemKeys.eventgrid_extension" -o tsv 2>/dev/null || echo "")
    if [ -n "$BLOB_KEY" ] && [ "$BLOB_KEY" != "null" ]; then break; fi
    BLOB_KEY=""
    sleep 10
done

if [ -z "$BLOB_KEY" ]; then
    echo "  WARNING: eventgrid_extension key unavailable; create the Event Grid"
    echo "  subscription manually (see README). Thumbnails will not generate yet."
else
    ENDPOINT_URL="https://${FUNCTION_APP_NAME}.azurewebsites.net/runtime/webhooks/eventgrid?functionName=process_photo&code=${BLOB_KEY}"
    STORAGE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)

    az eventgrid event-subscription delete \
        --name photo-upload-trigger --source-resource-id "$STORAGE_ID" \
        --output none 2>/dev/null || true

    az eventgrid event-subscription create \
        --name photo-upload-trigger \
        --source-resource-id "$STORAGE_ID" \
        --endpoint "$ENDPOINT_URL" \
        --endpoint-type webhook \
        --included-event-types Microsoft.Storage.BlobCreated \
        --subject-begins-with "/blobServices/default/containers/photos/blobs/users/" \
        --output none 2>/dev/null && echo "  Event Grid subscription created." \
        || echo "  WARNING: Event Grid subscription failed; create it manually."
fi
echo ""

# ============================================================
# Step 7: Smoke test
# ============================================================
echo "[7/7] Verifying the API..."
sleep 10
HTTP_CODE="000"
for i in $(seq 1 6); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_ENDPOINT/info" 2>/dev/null || echo "000")
    [ "$HTTP_CODE" = "200" ] && break
    echo "  Waiting for cold start (attempt $i/6)..."
    sleep 10
done
[ "$HTTP_CODE" = "200" ] && echo "  API is live." || echo "  WARNING: API not responding yet (HTTP $HTTP_CODE)."
echo ""

echo "=============================================="
echo " DEPLOYMENT SUMMARY"
echo "=============================================="
echo ""
echo " API Endpoint:   $API_ENDPOINT"
echo " Function App:   $FUNCTION_APP_NAME"
echo " Resource Group: $RESOURCE_GROUP"
echo " External tenant: $ENTRA_TENANT_SUBDOMAIN ($ENTRA_TENANT_ID)"
echo " App (client) ID: $ENTRA_CLIENT_ID"
echo ""
echo " Connect the app:"
echo "   1. Open app -> Drawer -> Settings"
echo "   2. Enter: $API_ENDPOINT"
echo "   3. Save and run Connection Test"
echo ""
echo " Logs:   az functionapp log tail --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP"
echo " Delete: az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo ""
echo "=============================================="
