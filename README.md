# Serverless MCP Server Infrastructure

Deploy any [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server on AWS, GCP, or Azure with zero idle cost, full CI/CD, and no long-lived cloud credentials — using Terraform and GitHub Actions OIDC.

**Cost at rest: $0.** You pay only when your MCP server receives requests.

Looking for the client? See **[mcp-client](https://github.com/nicculus/mcp-client)** — a CLI and Node.js library for calling these endpoints.

## Why this exists

Running an MCP server in the cloud usually means paying for an always-on container or VM. This setup uses serverless compute — AWS Lambda, GCP Cloud Run, or Azure Container Apps — so you pay per request and nothing when idle. The full pipeline is automated: `terraform plan` runs on every PR, `terraform apply` runs on merge to main, and cloud credentials are never stored as long-lived secrets.

## Architecture

Each cloud uses the same pattern: a serverless container that scales to zero, with secrets stored in a managed secret service and accessed via a managed identity (no credentials in code or Terraform state).

```
MCP Client
    │
    ▼
AWS:   API Gateway → Lambda (ECR image) → Secrets Manager
GCP:   Cloud Run (Artifact Registry image) → Secret Manager
Azure: Container Apps (ACR image) → Key Vault
```

### Two-phase Terraform setup (per cloud)

- **Bootstrap** — run once manually. Creates the state bucket, OIDC federation, registry, and CI service account/role.
- **Environment** — managed by CI after that. Creates all runtime resources.

## Prerequisites

- Accounts on whichever cloud(s) you want to deploy to
- [Terraform >= 1.12](https://developer.hashicorp.com/terraform/install) (`brew install hashicorp/tap/terraform`)
- Cloud CLIs: `aws`, `gcloud`, and/or `az`
- Docker (for building your MCP server image)
- GitHub repo

## Setup

Choose one or more clouds. Each is fully independent.

---

### AWS

#### 1. Bootstrap

```bash
cd terraform/bootstrap-aws
terraform init
terraform apply \
  -var="github_org=YOUR_GITHUB_USERNAME" \
  -var="budget_alert_email=YOUR_EMAIL"
```

> If you see `EntityAlreadyExists` for the OIDC provider, import it:
> ```bash
> terraform import aws_iam_openid_connect_provider.github \
>   arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
> terraform apply -var="github_org=YOUR_GITHUB_USERNAME" -var="budget_alert_email=YOUR_EMAIL"
> ```

#### 2. Add GitHub secrets

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `role_arn` output from bootstrap |

#### 3. Create secrets before first invocation

```bash
aws secretsmanager create-secret --name mcp-infra/api-key \
  --secret-string "$(openssl rand -hex 32)" --region us-east-1
aws secretsmanager create-secret --name mcp-infra/github-pat \
  --secret-string "YOUR_PAT" --region us-east-1
```

#### 4. Add a GitHub Actions variable

| Variable | Value |
|----------|-------|
| `TF_VAR_ALARM_EMAIL` | Your email address |

#### 5. Push and go

```bash
git push origin main
```

CI runs `terraform plan` on PRs and `terraform apply` on merge. The `deploy-image` workflow builds and pushes the Lambda image automatically on changes to `mcp-server/`.

---

### GCP

#### 1. Create a GCP project and enable billing

```bash
gcloud projects create YOUR_PROJECT_ID
gcloud billing projects link YOUR_PROJECT_ID --billing-account=YOUR_BILLING_ACCOUNT_ID
gcloud config set project YOUR_PROJECT_ID
```

#### 2. Bootstrap

```bash
cd terraform/bootstrap-gcp
terraform init
terraform apply \
  -var="gcp_project_id=YOUR_PROJECT_ID" \
  -var="github_org=YOUR_GITHUB_USERNAME" \
  -var="billing_account=YOUR_BILLING_ACCOUNT_ID"
```

#### 3. Add GitHub secrets

| Secret | Value |
|--------|-------|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `workload_identity_provider` output |
| `GCP_SERVICE_ACCOUNT` | `service_account_email` output |

Also add `TF_VAR_ALARM_EMAIL` as a GitHub Actions variable.

#### 4. Create secrets before first invocation

```bash
printf "YOUR_API_KEY" | gcloud secrets versions add mcp-api-key-dev \
  --data-file=- --project=YOUR_PROJECT_ID
printf "YOUR_GITHUB_PAT" | gcloud secrets versions add mcp-github-pat-dev \
  --data-file=- --project=YOUR_PROJECT_ID
```

Note: use `printf` (not `echo`) to avoid a trailing newline in the secret value.

#### 5. Push and go

CI applies Terraform and deploys the image automatically. The `terraform-gcp.yml` and `deploy-image-gcp.yml` workflows trigger on changes to their respective paths.

---

### Azure

#### 1. Log in and find your subscription ID

```bash
az login
az account show --query id -o tsv
```

#### 2. Bootstrap

```bash
cd terraform/bootstrap-azure
ARM_SKIP_PROVIDER_REGISTRATION=true terraform init
ARM_SKIP_PROVIDER_REGISTRATION=true terraform apply \
  -var="subscription_id=YOUR_SUBSCRIPTION_ID" \
  -var="github_org=YOUR_GITHUB_USERNAME"
```

#### 3. Add GitHub secrets

```bash
gh secret set AZURE_CLIENT_ID --body "client_id output"
gh secret set AZURE_TENANT_ID --body "tenant_id output"
gh secret set AZURE_SUBSCRIPTION_ID --body "subscription_id output"
gh secret set AZURE_STATE_STORAGE_ACCOUNT --body "state_storage_account output"
gh secret set AZURE_ACR_LOGIN_SERVER --body "acr_login_server output"
```

Also add `TF_VAR_ALARM_EMAIL` as a GitHub Actions variable.

#### 4. Register resource providers (once per subscription)

```bash
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait
```

#### 5. Create secrets before first invocation

```bash
az keyvault secret set --vault-name mcp-dev-kv \
  --name mcp-api-key-dev --value "YOUR_API_KEY"
az keyvault secret set --vault-name mcp-dev-kv \
  --name mcp-github-pat-dev --value "YOUR_GITHUB_PAT"
```

#### 6. Push and go

CI applies Terraform and deploys the image automatically. The `terraform-azure.yml` and `deploy-image-azure.yml` workflows trigger on changes to their respective paths.

---

## Repo structure

```
├── .github/workflows/
│   ├── terraform-aws.yml        # AWS: plan on PR, apply on merge
│   ├── deploy-image-aws.yml     # AWS: build + push to ECR, update Lambda
│   ├── terraform-gcp.yml        # GCP: plan on PR, apply on merge
│   ├── deploy-image-gcp.yml     # GCP: build + push to Artifact Registry, update Cloud Run
│   ├── terraform-azure.yml      # Azure: plan on PR, apply on merge
│   └── deploy-image-azure.yml   # Azure: build + push to ACR, update Container App
├── mcp-server/
│   ├── Dockerfile               # Generic container (CLOUD_PROVIDER build arg)
│   ├── Dockerfile.lambda        # AWS Lambda-specific (uses Lambda base image)
│   ├── server.py                # FastMCP server (replace with your own)
│   ├── cloud_secrets.py         # Routes secret fetching to aws/gcp/azure/env
│   ├── handler_lambda.py        # Lambda entrypoint (thin Mangum wrapper)
│   ├── requirements.txt         # Base deps (fastmcp-slim, uvicorn, starlette)
│   ├── requirements-aws.txt     # AWS extras (mangum, boto3)
│   ├── requirements-gcp.txt     # GCP extras (google-cloud-secret-manager)
│   └── requirements-azure.txt   # Azure extras (azure-keyvault-secrets, azure-identity)
└── terraform/
    ├── bootstrap-aws/           # AWS: run once manually
    ├── bootstrap-gcp/           # GCP: run once manually
    ├── bootstrap-azure/         # Azure: run once manually
    ├── environments/
    │   ├── aws-dev/             # AWS dev environment
    │   ├── gcp-dev/             # GCP dev environment
    │   └── azure-dev/           # Azure dev environment
    └── modules/
        ├── mcp-server-aws/      # AWS: Lambda + API Gateway + IAM + CloudWatch
        ├── mcp-server-gcp/      # GCP: Cloud Run + Secret Manager + Monitoring
        └── mcp-server-azure/    # Azure: Container Apps + Key Vault + Monitor
```

## Deploying your own MCP server

Replace `mcp-server/server.py` with your MCP server implementation. The `cloud_secrets.py` module handles secrets transparently across all three clouds — your server code just calls `get_secret("ENV_VAR_NAME")` and gets back the secret value regardless of which cloud it's running on.

```python
from cloud_secrets import get_secret

MY_API_KEY = get_secret("API_KEY_SECRET")  # works on AWS, GCP, and Azure
```

Any push to `main` that touches `mcp-server/` rebuilds and redeploys the image on all configured clouds automatically.

## Connecting a client

Use **[mcp-client](https://github.com/nicculus/mcp-client)** — a CLI and Node.js library for calling MCP servers over Streamable HTTP. It handles authentication, request formatting, and response parsing.

```bash
npx @nicculus/mcp-client tools list --url https://YOUR_ENDPOINT/mcp --key YOUR_API_KEY
```

## Authentication

Every request requires an `x-api-key` header. The key is stored in the cloud's secret service and never appears in logs or Terraform state.

```bash
curl -s -X POST https://YOUR_ENDPOINT/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

The server uses [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http) transport.

## Cost estimate

All three clouds have the same idle cost: **$0**.

| Cloud | Per-request cost |
|-------|-----------------|
| AWS Lambda + API Gateway | ~$1.20 / million requests |
| GCP Cloud Run | ~$0.40 / million requests |
| Azure Container Apps | ~$0.40 / million requests |

A lightly-used personal MCP server costs effectively nothing on any cloud.

## Cost protection

Each cloud has a budget alert and rate limiting:

| Cloud | Rate limiting | Alert |
|-------|--------------|-------|
| AWS | API Gateway throttling (10 rps / 50 burst) | CloudWatch alarm + Budget alert at 80% of $5 |
| GCP | Cloud Run max instances | Cloud Monitoring alert + Billing budget at 80% of $5 |
| Azure | Container App max replicas | Azure Monitor alert + (manual budget via Azure portal) |

## Known limitations / production hardening

- [ ] AWS: API Gateway CORS allows `*` origins — restrict for production
- [ ] AWS: ECR `force_delete = true` is dev-only — set to `false` in prod
- [ ] GCP: `deletion_protection = false` is intentional for dev — set to `true` in prod
- [ ] Azure: Key Vault `soft_delete_retention_days = 7` and `purge_protection_enabled = false` — enable purge protection in prod
- [ ] All clouds: add prod environments (`environments/prod/`, `environments/gcp-prod/`, `environments/azure-prod/`)

## License

MIT
