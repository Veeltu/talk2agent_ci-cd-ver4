#!/bin/bash
# Deploy agent to Vertex AI Agent Engine and register in Gemini Enterprise

set -e

# Setup directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Load .env
[[ -f "${ENV_FILE}" ]] && set -a && . "${ENV_FILE}" 2>/dev/null && set +a

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Variables
PROJECT_ID="${PROJECT:-${PROJECT_ID}}"

# Validate required env vars early
: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"
: "${STAGING_BUCKET:?STAGING_BUCKET must be set}"
: "${AGENT_DISPLAY_NAME:?AGENT_DISPLAY_NAME must be set}"
: "${AGENT_DESCRIPTION:?AGENT_DESCRIPTION must be set}"

# Auth setup:
# - If a service-account-key.json file is present, use it
# - Otherwise, fall back to the currently active gcloud account
SERVICE_ACCOUNT_KEY_PATH="${SERVICE_ACCOUNT_KEY_PATH:-$SCRIPT_DIR/service-account-key.json}"
if [[ -f "$SERVICE_ACCOUNT_KEY_PATH" ]]; then
  echo "🔐 Using service-account key: $SERVICE_ACCOUNT_KEY_PATH"
  export GOOGLE_APPLICATION_CREDENTIALS="$SERVICE_ACCOUNT_KEY_PATH"
  # Try to activate this service account for gcloud as well
  gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_KEY_PATH" --project="$PROJECT_ID" >/dev/null 2>&1 || \
    echo "⚠️  Could not activate service account in gcloud; continuing with existing gcloud auth."
else
  echo "ℹ️  No service-account-key.json found, using currently active gcloud account."
fi

# Change to project root (adk deploy requires this)
cd "$PROJECT_ROOT"

# ==============================================================================
# STEP 1: DEPLOY AGENT TO VERTEX AI AGENT ENGINE
# ==============================================================================

echo ""
echo "============================================================"
echo "🚀 VERTEX AI AGENT ENGINE DEPLOYMENT"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Staging Bucket: $STAGING_BUCKET"
echo "Display Name: $AGENT_DISPLAY_NAME"
[[ -n "$RESOURCE_NAME" ]] && echo "Resource Name: $RESOURCE_NAME (UPDATE mode)"
echo "============================================================"
echo ""

# Build deploy command
AGENT_DIR_NAME="$(basename "$SCRIPT_DIR")"
DEPLOY_CMD="uv run adk deploy agent_engine \
    --project=\"$PROJECT_ID\" \
    --region=\"$REGION\" \
    --staging_bucket=\"$STAGING_BUCKET\" \
    --display_name=\"$AGENT_DISPLAY_NAME\" \
    --description=\"$AGENT_DESCRIPTION\""

[[ -f "$ENV_FILE" ]] && DEPLOY_CMD="$DEPLOY_CMD --env_file=\"$ENV_FILE\""
DEPLOY_CMD="$DEPLOY_CMD $AGENT_DIR_NAME"

# Execute deployment with real-time output and capture to variable
echo "🚀 Starting deployment..."
TEMP_FILE="/tmp/deploy_$$.log"
trap "rm -f '$TEMP_FILE'" EXIT INT TERM

eval $DEPLOY_CMD 2>&1 | tee "$TEMP_FILE"
DEPLOY_OUTPUT=$(cat "$TEMP_FILE")

echo ""
echo "============================================================"
echo "✅ DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""

# Extract REASONING_ENGINE_ID from deployment output
REASONING_ENGINE_ID=$(echo "$DEPLOY_OUTPUT" | grep -oE 'reasoningEngines/[^/[:space:]"]+' | sed 's|reasoningEngines/||' | head -1)

# Get PROJECT_NUMBER (needed for both extraction and registration)
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")"

# If not found in output, try to get it from gcloud
if [[ -z "$REASONING_ENGINE_ID" ]]; then
    echo "🔍 Extracting REASONING_ENGINE_ID from gcloud..."
    REASONING_ENGINE_ID=$(gcloud ai reasoning-engines list \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --filter="displayName:$AGENT_DISPLAY_NAME" \
        --format="value(name)" 2>/dev/null | sed 's|.*reasoningEngines/||' | head -1)
fi

# If still not found, exit with error (no interactive prompt in CI/CD)
if [[ -z "$REASONING_ENGINE_ID" ]]; then
    echo "❌ Could not find REASONING_ENGINE_ID — aborting"
    exit 1
fi

echo "✅ REASONING_ENGINE_ID: $REASONING_ENGINE_ID"

# ==============================================================================
# STEP 2: CREATE / USE AGENTSPACE ENGINE (GEMINI ENTERPRISE)
# ==============================================================================

echo ""
echo "============================================================"
echo "🚀 SETTING UP GEMINI ENTERPRISE (AGENTSPACE)"
echo "============================================================"

TOKEN="$(gcloud auth print-access-token)"

# Enable APIs
gcloud services enable dialogflow.googleapis.com discoveryengine.googleapis.com aiplatform.googleapis.com --project "$PROJECT_ID" 2>/dev/null || true

# Auto-create Agentspace engine if AS_APP is not set
if [[ -z "${AS_APP:-}" ]]; then
    echo "📦 AS_APP not set — creating Agentspace engine automatically..."

    TIMESTAMP="$(date +%s)"
    AS_APP_ENGINE_ID="${AGENT_DISPLAY_NAME}-${TIMESTAMP}"
    DS_ID="${AGENT_DISPLAY_NAME}-ds-${TIMESTAMP}"

    # Step 2a: Create a Data Store (required by engine)
    echo "   📂 Creating data store: $DS_ID"
    DS_URL="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/dataStores?dataStoreId=${DS_ID}"

    DS_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
      "$DS_URL" \
      -d "{
        \"displayName\": \"${AGENT_DISPLAY_NAME}-datastore\",
        \"industryVertical\": \"GENERIC\",
        \"contentConfig\": \"NO_CONTENT\",
        \"solutionTypes\": [\"SOLUTION_TYPE_SEARCH\"]
      }")

    DS_HTTP_CODE="${DS_RESPONSE##*$'\n'}"
    DS_BODY="${DS_RESPONSE%$'\n'*}"

    if [[ ! "$DS_HTTP_CODE" =~ ^(200|201) ]]; then
        echo "❌ Failed to create data store (HTTP $DS_HTTP_CODE)"
        echo "$DS_BODY"
        exit 1
    fi
    echo "   ✅ Data store created: $DS_ID"

    # Step 2b: Create the Engine with data store reference
    echo "   🔧 Creating Agentspace engine: $AS_APP_ENGINE_ID"
    CREATE_URL="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/engines?engineId=${AS_APP_ENGINE_ID}"

    CREATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
      "$CREATE_URL" \
      -d "{
        \"displayName\": \"${AGENT_DISPLAY_NAME}-agentspace\",
        \"solutionType\": \"SOLUTION_TYPE_SEARCH\",
        \"industryVertical\": \"GENERIC\",
        \"appType\": \"APP_TYPE_INTRANET\",
        \"searchEngineConfig\": {
          \"searchTier\": \"SEARCH_TIER_ENTERPRISE\",
          \"searchAddOns\": [\"SEARCH_ADD_ON_LLM\"]
        },
        \"dataStoreIds\": [\"${DS_ID}\"]
      }")

    CREATE_HTTP_CODE="${CREATE_RESPONSE##*$'\n'}"
    CREATE_BODY="${CREATE_RESPONSE%$'\n'*}"

    if [[ "$CREATE_HTTP_CODE" =~ ^(200|201) ]]; then
        AS_APP="$AS_APP_ENGINE_ID"
        echo "   ✅ Created Agentspace engine: $AS_APP"
    else
        echo "❌ Failed to create Agentspace engine (HTTP $CREATE_HTTP_CODE)"
        echo "$CREATE_BODY"
        exit 1
    fi
else
    echo "✅ Using existing AS_APP: $AS_APP"
fi

echo ""
echo "============================================================"
echo "✅ AGENTSPACE ENGINE READY: $AS_APP"
echo "============================================================"

# ==============================================================================
# STEP 3: REGISTER AGENT IN AGENTSPACE (GEMINI ENTERPRISE)
# ==============================================================================

# Setup
REASONING_ENGINE="projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${REASONING_ENGINE_ID}"
API_URL="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents"

echo ""
echo "============================================================"
echo "🚀 REGISTERING AGENT IN GEMINI ENTERPRISE"
echo "============================================================"
echo "   Agent: $AGENT_DISPLAY_NAME"
echo "   Reasoning Engine: $REASONING_ENGINE_ID"
echo "   Agentspace App: $AS_APP"

# Register agent
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  "$API_URL" \
  -d "{
    \"displayName\": \"${AGENT_DISPLAY_NAME}\",
    \"description\": \"${AGENT_DESCRIPTION}\",
    \"adk_agent_definition\": {
      \"tool_settings\": {
        \"tool_description\": \"${AGENT_DESCRIPTION}\"
      },
      \"provisioned_reasoning_engine\": {
        \"reasoning_engine\": \"${REASONING_ENGINE}\"
      }
    }
  }")

HTTP_CODE="${RESPONSE##*$'\n'}"
BODY="${RESPONSE%$'\n'*}"

# Result
if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
    echo "✅ Agent registered successfully!"
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    echo ""
    echo "🎉 View in console: https://console.cloud.google.com/gen-app-builder/apps?project=${PROJECT_ID}"
else
    echo "❌ Registration failed (HTTP $HTTP_CODE)"
    echo "$BODY"
    exit 1
fi
