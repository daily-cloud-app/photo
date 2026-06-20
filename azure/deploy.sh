#!/bin/bash
# Daily Cloud Photo — Azure Deployment Script
# Deploys the complete backend infrastructure and function app code.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Azure Functions Core Tools installed (func)
#   - Python 3.11+
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh [RESOURCE_GROUP] [LOCATION] [APP_NAME]

set -e

# ── Configuration ──
RESOURCE_GROUP="${1:-daily-cloud-photo-rg}"
LOCATION="${2:-eastus}"
APP_NAME="${3:-dailycloudphoto}"
TEMPLATE_FILE="./azuredeploy.json"
FUNCTION_APP_DIR="./function_app"

echo "=============================================="
echo " Daily Cloud Photo — Azure Deployment"
echo "=============================================="
echo ""
echo " Resource Group: $RESOURCE_GROUP"
echo " Location:       $LOCATION"
echo " App Name:       $APP_NAME"
echo ""

# ── Step 1: Check prerequisites ──
echo "[1/6] Checking prerequisites..."

if ! command -v az &> /dev/null; then
    echo "ERROR: Azure CLI (az) is not installed."
    echo "Install: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

if ! command -v func &> /dev/null; then
    echo "WARNING: Azure Functions Core Tools (func) not installed."
    echo "Install: https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local"
    echo "Continuing with az CLI deployment only..."
    USE_FUNC_TOOLS=false
else
    USE_FUNC_TOOLS=true
fi

# Check if logged in
if ! az account show &> /dev/null; then
    echo "Not logged in to Azure. Running 'az login'..."
    az login
fi

echo "  Logged in as: $(az account show --query user.name -o tsv)"
echo "  Subscription: $(az account show --query name -o tsv)"
echo ""

# ── Step 2: Create Resource Group ──
echo "[2/6] Creating resource group..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
echo "  Resource group '$RESOURCE_GROUP' ready."
echo ""

# ── Step 3: Deploy ARM Template ──
echo "[3/6] Deploying ARM template (this may take 3-5 minutes)..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMPLATE_FILE" \
    --parameters appName="$APP_NAME" \
    --query "properties.outputs" \
    --output json)

FUNCTION_APP_NAME=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys, json; print(json.load(sys.stdin)['functionAppName']['value'])" 2>/dev/null || echo "")
API_ENDPOINT=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys, json; print(json.load(sys.stdin)['apiEndpoint']['value'])" 2>/dev/null || echo "")
STORAGE_ACCOUNT=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys, json; print(json.load(sys.stdin)['storageAccountName']['value'])" 2>/dev/null || echo "")

if [ -z "$FUNCTION_APP_NAME" ]; then
    echo "ERROR: Deployment failed. Check the Azure Portal for details."
    exit 1
fi

echo "  Function App: $FUNCTION_APP_NAME"
echo "  API Endpoint: $API_ENDPOINT"
echo "  Storage:      $STORAGE_ACCOUNT"
echo ""

# ── Step 4: Deploy Function App Code ──
echo "[4/6] Deploying function app code..."

if [ "$USE_FUNC_TOOLS" = true ]; then
    # Deploy using Azure Functions Core Tools
    cd "$FUNCTION_APP_DIR"
    func azure functionapp publish "$FUNCTION_APP_NAME" --python
    cd ..
else
    # Deploy using zip deployment via az CLI
    echo "  Creating deployment package..."
    DEPLOY_ZIP="/tmp/daily-cloud-photo-azure.zip"
    rm -f "$DEPLOY_ZIP"

    cd "$FUNCTION_APP_DIR"
    zip -r "$DEPLOY_ZIP" . -x "__pycache__/*" "*.pyc" ".venv/*" ".git/*"
    cd ..

    echo "  Uploading to Azure..."
    az functionapp deployment source config-zip \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNCTION_APP_NAME" \
        --src "$DEPLOY_ZIP" \
        --output none

    rm -f "$DEPLOY_ZIP"
fi

echo "  Code deployed successfully."
echo ""

# ── Step 5: Wait for function app to start ──
echo "[5/6] Waiting for function app to start..."
sleep 10

# Test the /info endpoint
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_ENDPOINT/info" 2>/dev/null || echo "000")
RETRY=0
while [ "$HTTP_CODE" != "200" ] && [ $RETRY -lt 6 ]; do
    echo "  Waiting for app to respond (attempt $((RETRY+1))/6)..."
    sleep 10
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_ENDPOINT/info" 2>/dev/null || echo "000")
    RETRY=$((RETRY+1))
done

if [ "$HTTP_CODE" = "200" ]; then
    echo "  Function app is running!"
else
    echo "  WARNING: Function app not responding yet (HTTP $HTTP_CODE)."
    echo "  It may take a few more minutes for cold start. Check Azure Portal."
fi
echo ""

# ── Step 6: Print summary ──
echo "[6/6] Deployment complete!"
echo ""
echo "=============================================="
echo " DEPLOYMENT SUMMARY"
echo "=============================================="
echo ""
echo " API Endpoint:    $API_ENDPOINT"
echo " Function App:    $FUNCTION_APP_NAME"
echo " Resource Group:  $RESOURCE_GROUP"
echo ""
echo " To connect the app:"
echo "   1. Open app → Drawer → Settings"
echo "   2. Enter: $API_ENDPOINT"
echo "   3. Save and run Connection Test"
echo ""
echo " To view logs:"
echo "   az functionapp log tail --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP"
echo ""
echo " To delete all resources:"
echo "   az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo ""
echo "=============================================="
