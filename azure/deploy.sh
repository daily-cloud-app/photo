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
ENTRA_USER_FLOW_NAME="${ENTRA_USER_FLOW_NAME:-DailyCloudPhotoSignUpSignIn}"

# External ID tenant creation (opt-in). When CREATE_TENANT=true, deploy.sh
# provisions a new external (CIAM) tenant via Bicep. Otherwise an existing
# tenant is used (ENTRA_TENANT_ID / ENTRA_CLIENT_ID).
CREATE_TENANT="${CREATE_TENANT:-false}"
TENANT_RESOURCE_NAME="${TENANT_RESOURCE_NAME:-dcp$(date +%s | tail -c 8)}"
TENANT_DISPLAY_NAME="${TENANT_DISPLAY_NAME:-Daily Cloud Photo External ID}"
TENANT_DATA_LOCATION="${TENANT_DATA_LOCATION:-United States}"
TENANT_COUNTRY_CODE="${TENANT_COUNTRY_CODE:-US}"
BICEP_TENANT="./bicep/identity_tenant.bicep"

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

# Remember the subscription so we can switch back after any external-tenant
# login (az login --tenant changes the active CLI context). SUB_ARG pins the
# subscription on every infrastructure-side az call.
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"
SUB_ARG=()
[ -n "$AZURE_SUBSCRIPTION_ID" ] && SUB_ARG=(--subscription "$AZURE_SUBSCRIPTION_ID")
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
# Step 3: Provision & configure Entra External ID (Bicep + Graph)
# ============================================================
echo "[3/7] Provisioning & configuring Microsoft Entra External ID..."

# Call Microsoft Graph with the external-tenant token.
# Usage: graph_call <METHOD> <URL> [<json-body>]
#   - prints the response body on stdout
#   - returns 0 only for HTTP 2xx; non-2xx returns 1 and logs the status/body
#     to stderr so callers can reliably detect failures (no silent success).
# We append the HTTP status as a trailing line (via -w) and split it off, which
# works across curl versions (older curl lacks --fail-with-body).
GRAPH_TOKEN=""
graph_call() {
    local method="$1" url="$2" body="${3:-}"
    local raw http_code resp
    if [ -n "$body" ]; then
        raw=$(curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
            -H "Authorization: Bearer $GRAPH_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$body")
    else
        raw=$(curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
            -H "Authorization: Bearer $GRAPH_TOKEN")
    fi
    http_code="${raw##*$'\n'}"   # last line
    resp="${raw%$'\n'*}"         # everything before the last line
    printf '%s' "$resp"
    case "$http_code" in
        2*) return 0 ;;
        *)
            echo "  Graph $method $url -> HTTP $http_code" >&2
            [ -n "$resp" ] && echo "  Response: $resp" >&2
            return 1
            ;;
    esac
}

json_get() {
    # json_get <key> — read a top-level key from stdin JSON.
    python3 -c "import sys,json
try:
    print(json.load(sys.stdin).get('$1',''))
except Exception:
    print('')" 2>/dev/null || echo ""
}

# ── 3a. Create the external tenant (opt-in) ──────────────────
# ciamDirectories requires a DELEGATED user token, so it is deployed with the
# currently signed-in user (not a managed identity). Skipped entirely when an
# existing tenant is provided.
if [ "$CREATE_TENANT" = "true" ] && [ -z "$ENTRA_TENANT_ID" ]; then
    echo "  Creating external (CIAM) tenant '$TENANT_DISPLAY_NAME' ..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" "${SUB_ARG[@]}" --output none

    TENANT_OUTPUT=$(az deployment group create \
        "${SUB_ARG[@]}" \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$BICEP_TENANT" \
        --parameters \
            tenantResourceName="$TENANT_RESOURCE_NAME" \
            tenantDisplayName="$TENANT_DISPLAY_NAME" \
            dataLocation="$TENANT_DATA_LOCATION" \
            countryCode="$TENANT_COUNTRY_CODE" \
        --query properties.outputs -o json 2>/dev/null || echo "")

    ENTRA_TENANT_ID=$(echo "$TENANT_OUTPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('tenantId',{}).get('value',''))" 2>/dev/null || echo "")

    if [ -z "$ENTRA_TENANT_ID" ]; then
        echo "  ERROR: External tenant creation failed."
        echo "  Creating ciamDirectories needs a delegated user token and"
        echo "  subscription permissions. Ensure you ran 'az login' as a user"
        echo "  (not a service principal) with rights to create the resource."
        exit 1
    fi
    echo "  External tenant created. tenant_id=$ENTRA_TENANT_ID"
fi

if [ -z "$ENTRA_TENANT_ID" ]; then
    echo "  ERROR: No external tenant available."
    echo "  Either set CREATE_TENANT=true to create one, or provide an existing"
    echo "  ENTRA_TENANT_ID (and ideally ENTRA_TENANT_SUBDOMAIN / ENTRA_CLIENT_ID)."
    exit 1
fi

# ── 3b. Sign in to the external tenant for Graph (1 interactive login) ──
# Graph operations below run against the external tenant. Acquire a token; if
# the current session isn't signed in to that tenant, request a one-time login.
GRAPH_TOKEN=$(az account get-access-token --tenant "$ENTRA_TENANT_ID" \
    --resource-type ms-graph --query accessToken -o tsv 2>/dev/null || echo "")

if [ -z "$GRAPH_TOKEN" ]; then
    echo "  A one-time sign-in to the external tenant is required."
    echo "  Launching: az login --tenant $ENTRA_TENANT_ID --allow-no-subscriptions"
    az login --tenant "$ENTRA_TENANT_ID" --allow-no-subscriptions --only-show-errors >/dev/null
    GRAPH_TOKEN=$(az account get-access-token --tenant "$ENTRA_TENANT_ID" \
        --resource-type ms-graph --query accessToken -o tsv 2>/dev/null || echo "")
fi

if [ -z "$GRAPH_TOKEN" ]; then
    echo "  ERROR: Could not obtain a Microsoft Graph token for the external tenant."
    echo "  Run 'az login --tenant $ENTRA_TENANT_ID --allow-no-subscriptions' and retry."
    exit 1
fi

# Resolve the tenant subdomain from its verified onmicrosoft.com domain when
# not explicitly provided (Native Auth base URL needs the subdomain).
if [ -z "$ENTRA_TENANT_SUBDOMAIN" ]; then
    DOMAINS_JSON=$(graph_call GET "https://graph.microsoft.com/v1.0/domains")
    ENTRA_TENANT_SUBDOMAIN=$(echo "$DOMAINS_JSON" | python3 -c "
import sys,json
try:
    doms=[d['id'] for d in json.load(sys.stdin).get('value',[])]
    onms=[d for d in doms if d.endswith('.onmicrosoft.com')]
    print(onms[0].split('.onmicrosoft.com')[0] if onms else '')
except Exception:
    print('')" 2>/dev/null || echo "")
    [ -n "$ENTRA_TENANT_SUBDOMAIN" ] && echo "  Resolved tenant subdomain: $ENTRA_TENANT_SUBDOMAIN"
fi

# ── 3b2. Graph automation app (application permissions) ──────
# The Azure CLI first-party token lacks the high-privilege delegated scopes
# (Policy.ReadWrite.AuthenticationMethod, EventListener.ReadWrite.All) required
# to configure the Email OTP policy and user flows — even for a Global Admin.
# So we provision a short-lived dedicated app with those APPLICATION permissions,
# grant admin consent, and use its client-credentials token for the Graph calls
# below. The app is deleted at the end of Step 3.
GRAPH_MSGRAPH_APPID="00000003-0000-0000-c000-000000000000"
GRAPH_AUTOMATION_APPID=""
GRAPH_AUTOMATION_OBJECT_ID=""

echo "  Provisioning temporary Graph automation app (application permissions)..."
AUTO_APP=$(az ad app create --display-name "DCP Graph Automation (temp)" \
    --sign-in-audience AzureADMyOrg -o json 2>/dev/null || echo "")
GRAPH_AUTOMATION_APPID=$(echo "$AUTO_APP" | json_get appId)
GRAPH_AUTOMATION_OBJECT_ID=$(echo "$AUTO_APP" | json_get id)

if [ -z "$GRAPH_AUTOMATION_APPID" ]; then
    echo "  ERROR: Could not create the Graph automation app."
    exit 1
fi

az ad sp create --id "$GRAPH_AUTOMATION_APPID" >/dev/null 2>&1 || true
AUTO_SPID=$(az ad sp show --id "$GRAPH_AUTOMATION_APPID" --query id -o tsv 2>/dev/null || echo "")
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_MSGRAPH_APPID" --query id -o tsv)

# Resolve the app-role (application permission) ids from the Graph SP.
role_id() { az ad sp show --id "$GRAPH_MSGRAPH_APPID" --query "appRoles[?value=='$1'].id | [0]" -o tsv; }
ROLE_POLICY=$(role_id "Policy.ReadWrite.AuthenticationMethod")
ROLE_FLOW=$(role_id "EventListener.ReadWrite.All")
ROLE_APP=$(role_id "Application.ReadWrite.All")

# Grant admin consent by assigning the app roles to the automation SP.
grant_role() {
    az rest --method POST \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$AUTO_SPID/appRoleAssignments" \
        --headers "Content-Type=application/json" \
        --body "{\"principalId\":\"$AUTO_SPID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$1\"}" \
        --only-show-errors >/dev/null 2>&1 || true
}
grant_role "$ROLE_POLICY"
grant_role "$ROLE_FLOW"
grant_role "$ROLE_APP"

# Short-lived client secret for the client-credentials grant.
AUTO_SECRET=$(az ad app credential reset --id "$GRAPH_AUTOMATION_APPID" --append \
    --query password -o tsv --only-show-errors 2>/dev/null || echo "")
if [ -z "$AUTO_SECRET" ]; then
    echo "  ERROR: Could not create a client secret for the automation app."
    exit 1
fi

# Delete the automation app on exit (best effort), so no standing credential
# is left behind after deployment.
cleanup_graph_app() {
    [ -n "$GRAPH_AUTOMATION_OBJECT_ID" ] && \
        az ad app delete --id "$GRAPH_AUTOMATION_OBJECT_ID" --only-show-errors 2>/dev/null || true
}
trap cleanup_graph_app EXIT

# Acquire the client-credentials token (retry until consent propagates).
echo "  Waiting for admin consent to propagate..."
GRAPH_TOKEN=""
for _ in $(seq 1 12); do
    sleep 10
    GRAPH_TOKEN=$(curl -s -X POST \
        "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/token" \
        -d "client_id=$GRAPH_AUTOMATION_APPID" \
        -d "scope=https://graph.microsoft.com/.default" \
        -d "client_secret=$AUTO_SECRET" \
        -d "grant_type=client_credentials" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
    # Verify the token actually carries the required app roles before using it.
    if [ -n "$GRAPH_TOKEN" ]; then
        HAS_ROLE=$(echo "$GRAPH_TOKEN" | cut -d. -f2 | tr '_-' '/+' | \
            python3 -c "
import sys,base64,json
s=sys.stdin.read().strip()
s+='='*(-len(s)%4)
try:
    d=json.loads(base64.b64decode(s))
    print('yes' if 'Policy.ReadWrite.AuthenticationMethod' in (d.get('roles') or []) else 'no')
except Exception:
    print('no')" 2>/dev/null || echo "no")
        [ "$HAS_ROLE" = "yes" ] && break
        GRAPH_TOKEN=""
    fi
done

if [ -z "$GRAPH_TOKEN" ]; then
    echo "  ERROR: Could not obtain an app token with the required Graph roles."
    echo "  Admin consent may not have propagated. Re-run in a minute."
    exit 1
fi
echo "  Graph automation token ready."

# ── 3c. App registration (public client + native authentication) ──
if [ -n "$ENTRA_CLIENT_ID" ]; then
    echo "  Using existing app registration: $ENTRA_CLIENT_ID"
    APP_JSON=$(graph_call GET "https://graph.microsoft.com/v1.0/applications(appId='$ENTRA_CLIENT_ID')"); RC=$?
    if [ $RC -ne 0 ]; then
        echo "  ERROR: Could not read the existing app registration ($ENTRA_CLIENT_ID)."
        exit 1
    fi
    ENTRA_APP_OBJECT_ID=$(echo "$APP_JSON" | json_get id)
else
    echo "  Creating app registration '$ENTRA_APP_DISPLAY_NAME' ..."
    # Public client (isFallbackPublicClient) + native auth enabled. The
    # nativeAuthenticationApisEnabled flag turns on the native-auth API.
    APP_BODY=$(python3 - "$ENTRA_APP_DISPLAY_NAME" <<'PY'
import json, sys
print(json.dumps({
    "displayName": sys.argv[1],
    "signInAudience": "AzureADMyOrg",
    "isFallbackPublicClient": True,
    "publicClient": {"redirectUris": ["https://login.microsoftonline.com/common/oauth2/nativeclient"]},
    "nativeAuthenticationApisEnabled": "all",
}))
PY
)
    CREATED_APP=$(graph_call POST "https://graph.microsoft.com/v1.0/applications" "$APP_BODY"); RC=$?
    ENTRA_CLIENT_ID=$(echo "$CREATED_APP" | json_get appId)
    ENTRA_APP_OBJECT_ID=$(echo "$CREATED_APP" | json_get id)

    if [ $RC -ne 0 ] || [ -z "$ENTRA_CLIENT_ID" ]; then
        echo "  ERROR: App registration failed."
        exit 1
    fi
    echo "  App registration created. client_id=$ENTRA_CLIENT_ID"
fi

# Ensure native authentication is enabled on the app (idempotent for reuse).
# This is required for the native-auth API to work, so fail loudly on error.
if [ -n "$ENTRA_APP_OBJECT_ID" ]; then
    if ! graph_call PATCH "https://graph.microsoft.com/v1.0/applications/$ENTRA_APP_OBJECT_ID" \
        '{"nativeAuthenticationApisEnabled":"all","isFallbackPublicClient":true}' >/dev/null; then
        echo "  ERROR: Failed to enable native authentication on the app."
        exit 1
    fi
else
    echo "  ERROR: Could not resolve the app object id; cannot enable native auth."
    exit 1
fi

# ── 3d. Enable Email OTP tenant policy (required for SSPR) ──
# Email one-time passcode must be enabled tenant-wide so native credential
# recovery (self-service password reset) works. Idempotent PATCH.
echo "  Enabling Email OTP authentication method (SSPR prerequisite)..."
if ! graph_call PATCH \
    "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/email" \
    '{"@odata.type":"#microsoft.graph.emailAuthenticationMethodConfiguration","state":"enabled","allowExternalIdToUseEmailOtp":"enabled"}' >/dev/null; then
    echo "  ERROR: Failed to enable the Email OTP policy (SSPR prerequisite)."
    echo "  The automation app needs the 'Policy.ReadWrite.AuthenticationMethod' application permission."
    exit 1
fi

# ── 3e. Sign-up/sign-in user flow (Email+Password) + app association ──
# Idempotent: create the flow if absent; if a flow with our name already exists,
# converge its state by ensuring the current app is in includeApplications.
echo "  Configuring sign-up/sign-in user flow '$ENTRA_USER_FLOW_NAME'..."
FLOWS_JSON=$(graph_call GET \
    "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows?\$select=id,displayName"); RC=$?
if [ $RC -ne 0 ]; then
    echo "  ERROR: Could not list user flows."
    echo "  Ensure the signed-in user has the 'External ID User Flow Administrator' role."
    exit 1
fi
EXISTING_FLOW_ID=$(echo "$FLOWS_JSON" | python3 -c "
import sys,json
name='$ENTRA_USER_FLOW_NAME'
try:
    for f in json.load(sys.stdin).get('value',[]):
        if f.get('displayName')==name:
            print(f.get('id','')); break
except Exception:
    pass" 2>/dev/null || echo "")

if [ -n "$EXISTING_FLOW_ID" ]; then
    echo "  Found existing user flow (id=$EXISTING_FLOW_ID); converging configuration..."
    ENTRA_USER_FLOW_ID="$EXISTING_FLOW_ID"

    # Read the flow's current application association.
    FLOW_JSON=$(graph_call GET \
        "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows/$EXISTING_FLOW_ID"); RC=$?
    if [ $RC -ne 0 ]; then
        echo "  ERROR: Could not read the existing user flow."
        exit 1
    fi

    APP_INCLUDED=$(echo "$FLOW_JSON" | python3 -c "
import sys,json
app_id='$ENTRA_CLIENT_ID'
try:
    d=json.load(sys.stdin)
    apps=(d.get('conditions') or {}).get('applications') or {}
    inc=apps.get('includeApplications') or []
    print('yes' if any(a.get('appId')==app_id for a in inc) else 'no')
except Exception:
    print('no')" 2>/dev/null || echo "no")

    if [ "$APP_INCLUDED" = "yes" ]; then
        echo "  App $ENTRA_CLIENT_ID is already associated with the flow."
    else
        echo "  Associating app $ENTRA_CLIENT_ID with the existing flow..."
        # Merge the current app into includeApplications (don't drop existing).
        COND_BODY=$(echo "$FLOW_JSON" | python3 -c "
import sys,json
app_id='$ENTRA_CLIENT_ID'
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
apps=((d.get('conditions') or {}).get('applications') or {})
inc=apps.get('includeApplications') or []
if not any(a.get('appId')==app_id for a in inc):
    inc.append({'appId': app_id})
print(json.dumps({'conditions': {'applications': {'includeApplications': inc}}}))")
        if ! graph_call PATCH \
            "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows/$EXISTING_FLOW_ID" \
            "$COND_BODY" >/dev/null; then
            echo "  ERROR: Failed to associate the app with the existing user flow."
            exit 1
        fi
        echo "  App association added to the existing flow."
    fi
else
    FLOW_BODY=$(python3 - "$ENTRA_USER_FLOW_NAME" "$ENTRA_CLIENT_ID" <<'PY'
import json, sys
name, app_id = sys.argv[1], sys.argv[2]
print(json.dumps({
    "@odata.type": "#microsoft.graph.externalUsersSelfServiceSignUpEventsFlow",
    "displayName": name,
    "conditions": {"applications": {"includeApplications": [{"appId": app_id}]}},
    "onInteractiveAuthFlowStart": {
        "@odata.type": "#microsoft.graph.onInteractiveAuthFlowStartExternalUsersSelfServiceSignUp",
        "isSignUpAllowed": True,
    },
    "onAuthenticationMethodLoadStart": {
        "@odata.type": "#microsoft.graph.onAuthenticationMethodLoadStartExternalUsersSelfServiceSignUp",
        "identityProviders": [{"id": "EmailPassword-OAUTH"}],
    },
    "onAttributeCollection": {
        "@odata.type": "#microsoft.graph.onAttributeCollectionExternalUsersSelfServiceSignUp",
        "attributes": [
            {"id": "email", "displayName": "Email Address", "description": "Email address of the user",
             "userFlowAttributeType": "builtIn", "dataType": "string"},
            {"id": "displayName", "displayName": "Display Name", "description": "Display Name of the User.",
             "userFlowAttributeType": "builtIn", "dataType": "string"},
        ],
        "attributeCollectionPage": {"views": [{"inputs": [
            {"attribute": "email", "label": "Email Address", "inputType": "text", "hidden": True,
             "editable": False, "writeToDirectory": True, "required": True,
             "validationRegEx": "^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*$"},
            {"attribute": "displayName", "label": "Display Name", "inputType": "text", "hidden": False,
             "editable": True, "writeToDirectory": True, "required": False,
             "validationRegEx": "^[a-zA-Z_][0-9a-zA-Z_ ]*[0-9a-zA-Z_]+$"},
        ]}]},
    },
}))
PY
)
    CREATED_FLOW=$(graph_call POST \
        "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows" "$FLOW_BODY"); RC=$?
    ENTRA_USER_FLOW_ID=$(echo "$CREATED_FLOW" | json_get id)

    if [ $RC -ne 0 ] || [ -z "$ENTRA_USER_FLOW_ID" ]; then
        echo "  ERROR: User flow creation failed."
        echo "  Verify the signed-in user has the 'External ID User Flow Administrator' role."
        exit 1
    fi
    echo "  User flow created and associated with the app (id=$ENTRA_USER_FLOW_ID)."
fi

if [ -z "$ENTRA_CLIENT_ID" ] || [ -z "$ENTRA_TENANT_SUBDOMAIN" ]; then
    echo "  ERROR: Missing ENTRA_CLIENT_ID or ENTRA_TENANT_SUBDOMAIN after setup."
    exit 1
fi

# Delete the temporary Graph automation app now, while still in the external
# tenant context, so no standing credential remains. Clear the EXIT trap since
# cleanup is done here explicitly.
echo "  Removing temporary Graph automation app..."
cleanup_graph_app
trap - EXIT
GRAPH_TOKEN=""

# Switch the active CLI context back to the subscription for infra deployment.
if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" --only-show-errors 2>/dev/null || true
fi
echo ""

# ============================================================
# Step 4: Deploy infrastructure with Bicep
# ============================================================
echo "[4/7] Creating resource group and deploying Bicep..."

# SUB_ARG (defined in Step 1) pins the subscription: an external-tenant login
# in Step 3 may have changed the active CLI context.
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" "${SUB_ARG[@]}" --output none

DEPLOYMENT_OUTPUT=$(az deployment group create \
    "${SUB_ARG[@]}" \
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
    "${SUB_ARG[@]}" \
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
    BLOB_KEY=$(az functionapp keys list "${SUB_ARG[@]}" --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" \
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
    STORAGE_ID=$(az storage account show "${SUB_ARG[@]}" --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)

    az eventgrid event-subscription delete \
        --name photo-upload-trigger --source-resource-id "$STORAGE_ID" \
        --output none 2>/dev/null || true

    az eventgrid event-subscription create \
        "${SUB_ARG[@]}" \
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
