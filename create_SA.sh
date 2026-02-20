#!/bin/bash
set -e

# Load .env (same file used by full_deploy.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "${ENV_FILE}" ]] && set -a && . "${ENV_FILE}" 2>/dev/null && set +a

# Variables from .env (with defaults)
PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set in .env}"
SA_NAME="${SA_NAME:-agent-deployer}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Create Service Account (skip if already exists)
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "ℹ️  Service account $SA_EMAIL already exists — skipping creation"
else
    echo "🔧 Creating service account: $SA_EMAIL"
    gcloud iam service-accounts create $SA_NAME \
        --project=$PROJECT_ID \
        --display-name="Agent Deployer Service Account" \
        --description="Service Account for deploying agents to Vertex AI Agent Engine"
    echo "✅ Service account created"
fi

#--------------------------------------------------

echo "🔐 Adding IAM policies..."
c
# Add IAM policies
ROLES=(
    "roles/aiplatform.user"             # Vertex AI - create and manage reasoning engines
    "roles/storage.admin"               # Storage - save artifacts to staging bucket
    "roles/discoveryengine.admin"       # Discovery Engine - register agents in Gemini Enterprise
    "roles/viewer"                      # Project Viewer - for gcloud projects describe
    "roles/serviceusage.serviceUsageAdmin" # Service Usage - enable APIs + X-Goog-User-Project header
    "roles/dialogflow.admin"            # Dialogflow - create agents in Agentspace
    "roles/apihub.admin"               # API Hub - full access to specs and search APIs
)

for ROLE in "${ROLES[@]}"; do
    echo "   ➕ $ROLE"
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$ROLE" \
        --quiet >/dev/null
done

echo "✅ All IAM policies applied"

#--------------------------------------------------

# Create key (only if file doesn't exist)
if [[ -f "service-account-key.json" ]]; then
    echo "ℹ️  service-account-key.json already exists — skipping key creation"
else
    gcloud iam service-accounts keys create service-account-key.json \
        --iam-account=${SA_EMAIL} \
        --project=$PROJECT_ID
    echo "✅ Key saved to: service-account-key.json"
fi
