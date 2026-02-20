# Talk2API – CI/CD Deployment

AI agent built on Google ADK that dynamically discovers and calls APIs from API Hub.  
Automatically deployed to **Vertex AI Agent Engine** and registered in **Gemini Enterprise (Agentspace)**.  
If no `AS_APP` is set in `config.env`, the script will create a new Gemini Enterprise app and register the agent to it.

## Setup

### 1. Create Service Account

```bash
./create_SA.sh
```

Creates `agent-deployer` SA with required roles (Vertex AI, Storage, API Hub, Agentspace, etc.) and saves key to `service-account-key.json`.

### 2. `config.env` (committed to repo)

Non-sensitive deployment config. Change any value and push — the pipeline picks it up automatically.

| Variable | Description |
|---|---|
| `PROJECT_ID` | GCP project ID |
| `REGION` | Deployment region |
| `STAGING_BUCKET` | GCS bucket for staging |
| `AGENT_DISPLAY_NAME` | Agent name |
| `AGENT_DESCRIPTION` | Agent description |
| `APIHUB_SEARCH_URL` | API Hub search endpoint URL |
| `AS_APP` | Agentspace engine ID (empty = auto-create) |

### 3. GitHub Secrets (set once in GitHub UI)

Go to repo **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Description |
|---|---|
| `GCP_SERVICE_ACCOUNT_KEY` | Contents of `service-account-key.json` (also used for API Hub auth at runtime) |
| `APIKEY_CREDENTIAL` | CRM API key |
| `GOOGLE_API_KEY` | Gemini API key |

## How the Pipeline Works

1. Push to `main`/`master` (or manual trigger) starts the workflow
2. Builds `.env` from `config.env` + secrets (including SA key JSON for runtime API Hub access)
3. Runs `full_deploy.sh` → deploys to Vertex AI + registers in Gemini Enterprise
4. At runtime, agent uses `APIHUB_SA_KEY_JSON` (from `.env`) to authenticate with API Hub — no static tokens needed
