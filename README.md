# Talk2API – CI/CD Deployment

AI agent built on Google ADK that dynamically discovers and calls APIs from API Hub.  
Automatically deployed to **Vertex AI Agent Engine** and registered in **Gemini Enterprise (Agentspace)**.  
If no `AS_APP` is set in `config.env`, the script will create a new Gemini Enterprise app and register the agent to it.

## Configuration

### `config.env` (committed to repo — easy to edit)

Non-sensitive deployment config. Change any value and push — the pipeline picks it up automatically.

| Variable | Description |
|---|---|
| `PROJECT_ID` | GCP project ID |
| `REGION` | Deployment region |
| `STAGING_BUCKET` | GCS bucket for staging |
| `AGENT_DISPLAY_NAME` | Agent name |
| `AGENT_DESCRIPTION` | Agent description |
| `AS_APP` | Agentspace engine ID (empty = auto-create) |

### GitHub Secrets (set once in GitHub UI)

Go to repo **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Description |
|---|---|
| `GCP_SERVICE_ACCOUNT_KEY` | Contents of `service-account-key.json` |
| `APIKEY_CREDENTIAL` | CRM API key |
| `GOOGLE_API_KEY` | Gemini API key |
| `APIHUB_ACCESS_TOKEN` | GCP token for API Hub |
| `APIHUB_SEARCH_URL` | API Hub search endpoint URL |

## How the Pipeline Works

1. Push to `main`/`master` (or manual trigger) starts the workflow
2. Runner installs Python, `uv`, and ADK dependencies
3. Builds `.env` from `config.env` (repo) + secrets (GitHub)
4. Runs `full_deploy.sh` → deploys to Vertex AI + registers in Gemini Enterprise
5. Cleans up keys after deployment
