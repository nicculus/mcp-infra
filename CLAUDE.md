# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform + GitHub Actions infrastructure for deploying MCP servers on AWS, GCP, and Azure. Zero idle cost — pay per request only.

- **AWS**: Lambda + API Gateway
- **GCP**: Cloud Run
- **Azure**: Container Apps

## Common commands

```bash
# Format all Terraform files (CI enforces this)
terraform fmt -recursive

# Lint (CI enforces this)
tflint --recursive

# AWS bootstrap (run once manually before anything else)
cd terraform/bootstrap
terraform init
terraform apply -var="github_org=YOUR_GITHUB_USERNAME" -var="budget_alert_email=YOU@example.com"

# GCP bootstrap
cd terraform/bootstrap-gcp
terraform init
terraform apply -var="gcp_project_id=YOUR_PROJECT" -var="github_org=YOUR_GITHUB_USERNAME" -var="billing_account=YOUR_BILLING_ACCOUNT"

# Azure bootstrap
cd terraform/bootstrap-azure
ARM_SKIP_PROVIDER_REGISTRATION=true terraform init
ARM_SKIP_PROVIDER_REGISTRATION=true terraform apply -var="subscription_id=YOUR_SUB_ID" -var="github_org=YOUR_GITHUB_USERNAME"

# AWS dev environment (after bootstrap)
cd terraform/environments/dev
terraform init -backend-config=backend.tfbackend
terraform validate
terraform plan -var="alarm_email=YOU@example.com"

# GCP dev environment (after bootstrap)
cd terraform/environments/gcp-dev
terraform init -backend-config="bucket=mcp-infra-tfstate-YOUR_PROJECT_ID"
terraform plan -var="alarm_email=YOU@example.com"

# Azure dev environment (after bootstrap)
cd terraform/environments/azure-dev
terraform init -backend-config="storage_account_name=mcpinfratfstate" -backend-config="subscription_id=YOUR_SUB_ID" -backend-config="resource_group_name=mcp-infra-bootstrap"
terraform plan -var="subscription_id=YOUR_SUB_ID" -var="acr_login_server=mcpinfraregistry.azurecr.io" -var="alarm_email=YOU@example.com"
```

## Architecture

```
AWS:   Client → API Gateway (HTTP) → Lambda (ECR image) → Secrets Manager
GCP:   Client → Cloud Run (Artifact Registry image) → Secret Manager
Azure: Client → Container Apps (ACR image) → Key Vault
```

All three use the same `cloud_secrets.py` abstraction — the server code calls `get_secret("ENV_VAR_NAME")` and the right cloud SDK handles the fetch transparently. `CLOUD_PROVIDER` env var routes to the correct backend.

### AWS resources per environment

- **ECR** — container image repository (IMMUTABLE tags, KMS-encrypted, lifecycle: keep last 10)
- **Lambda** — container image function, X-Ray tracing, reserved concurrency cap, KMS-encrypted env vars
- **API Gateway v2** — HTTP API, `$default` catch-all route, per-route throttling
- **KMS** — single key shared across CloudWatch logs, SNS, SQS, Lambda env vars
- **SQS** — dead letter queue for failed Lambda invocations (14-day retention, KMS-encrypted)
- **CloudWatch** — log groups for Lambda and API Gateway (365-day retention, KMS-encrypted), invocation and error alarms
- **SNS** — alarm notifications topic with email subscription (KMS-encrypted)
- **IAM** — Lambda execution role with least-privilege inline policy (Secrets Manager, KMS, SQS, X-Ray)

### GCP resources per environment

- **Cloud Run v2** — container service, scales to zero, TCP startup probe
- **Artifact Registry** — Docker image repository (bootstrap, keep last 10)
- **Secret Manager** — API key + GitHub PAT secrets (shell created by Terraform, values set manually)
- **Service Account** — runtime identity with secretAccessor IAM binding
- **KMS** — key ring + crypto key for Cloud Run (90-day rotation)
- **Cloud Monitoring** — error rate and request volume alert policies with email channel

### Azure resources per environment

- **Container App** — scales to zero, system-assigned + user-assigned managed identity, TCP startup probe
- **Container App Environment** — shared managed environment
- **Key Vault** — API key + GitHub PAT secrets (shell created by Terraform, values set manually)
- **User-assigned identity** — dedicated AcrPull identity (avoids chicken-and-egg with system identity)
- **Azure Monitor** — metric alert for 5xx errors with email action group

## Module structure

```
terraform/modules/mcp-server/          — AWS module
├── main.tf         — Lambda function
├── variables.tf    — variable declarations with validation
├── iam.tf          — Lambda execution role, policies
├── kms.tf          — KMS key and alias
├── api_gateway.tf  — API Gateway v2
├── monitoring.tf   — DLQ, CloudWatch, SNS
└── outputs.tf      — service_url (shared name), api_endpoint (alias), etc.

terraform/modules/mcp-server-gcp/      — GCP module
├── main.tf         — Cloud Run service + public IAM
├── variables.tf
├── iam.tf          — service account + Secret Manager bindings
├── kms.tf          — KMS key ring + crypto key
├── secrets.tf      — Secret Manager secret shells
├── monitoring.tf   — alert policies + notification channel
└── outputs.tf      — service_url, service_name, etc.

terraform/modules/mcp-server-azure/    — Azure module
├── main.tf         — Container App + user-assigned identity + ACR role
├── variables.tf
├── keyvault.tf     — Key Vault + access policies + secret shells
├── monitoring.tf   — action group + metric alert
└── outputs.tf      — service_url, container_app_name, etc.
```

All three modules expose `service_url` as the canonical endpoint output.

## Shared variable interface

These variables have identical names, types, and semantics across all three modules:

| Variable | Type | Default | Notes |
|----------|------|---------|-------|
| `environment` | string | `"dev"` | Validated: dev/staging/prod |
| `container_image` | string | — | Full URI including tag |
| `memory_size` | number/string | 512 / "0.5Gi" | Unit differs by cloud |
| `timeout` | number | 30 | Seconds; AWS max 900, GCP max 3600 |
| `alarm_email` | string | — | Monitoring notifications |

Cloud-specific variables (e.g. `gcp_project_id`, `acr_login_server`) are additional — not shared.

## Two-phase setup (all clouds)

1. **Bootstrap** — run once manually from a local machine with elevated credentials. Uses local Terraform state. Creates: state backend, container registry, OIDC/federated identity for GitHub Actions, CI service principal/role.

2. **Environment** — managed by CI/CD. Uses cloud-native remote backend.

## Security model

- **No long-lived credentials** — GitHub Actions uses OIDC federation on all three clouds (AWS OIDC provider, GCP Workload Identity Federation, Azure federated credentials). No cloud access keys stored anywhere.
- **API authentication** — `x-api-key` header validated in application code against a secret fetched from the cloud's secret service. Not enforced at the gateway layer.
- **Managed identity at runtime** — Lambda execution role (AWS), Cloud Run service account (GCP), system-assigned managed identity (Azure) — each has only the permissions needed to fetch secrets and run.
- **Blast radius caps** — Lambda reserved concurrency (default 10), Cloud Run max instances (default 10), Container App max replicas (default 10).

## CI/CD

Six workflows — one terraform + one deploy-image per cloud:

| Workflow | Trigger paths | What it does |
|----------|--------------|--------------|
| `terraform.yml` | `terraform/**` | AWS: tflint, checkov, plan on PR, apply on merge |
| `deploy-image.yml` | `mcp-server/**` | AWS: build with `Dockerfile.lambda`, push to ECR, update Lambda |
| `terraform-gcp.yml` | `terraform/environments/gcp-dev/**`, `terraform/modules/mcp-server-gcp/**` | GCP: plan on PR, apply on merge |
| `deploy-image-gcp.yml` | `mcp-server/**` | GCP: build with `--build-arg CLOUD_PROVIDER=gcp`, push to Artifact Registry, `gcloud run services update` |
| `terraform-azure.yml` | `terraform/environments/azure-dev/**`, `terraform/modules/mcp-server-azure/**` | Azure: plan on PR, apply on merge |
| `deploy-image-azure.yml` | `mcp-server/**` | Azure: build with `--build-arg CLOUD_PROVIDER=azure`, push to ACR, `az containerapp update` |

All deploy workflows use `lifecycle { ignore_changes = [image] }` in Terraform — Terraform sets the image only on first creation; the deploy workflow owns it after that.

## Critical setup steps

### AWS
1. Run bootstrap. Add `role_arn` output as `AWS_ROLE_ARN` GitHub secret.
2. Create secrets: `aws secretsmanager create-secret --name mcp-infra/api-key ...` and `mcp-infra/github-pat`.
3. Add `TF_VAR_ALARM_EMAIL` as a GitHub Actions variable.
4. Confirm the SNS email subscription after first apply.

### GCP
1. Run bootstrap. Add `workload_identity_provider` and `service_account_email` outputs as GitHub secrets `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_SERVICE_ACCOUNT`.
2. Add `TF_VAR_ALARM_EMAIL` as a GitHub Actions variable.
3. Set secrets: `printf "VALUE" | gcloud secrets versions add mcp-api-key-dev --data-file=- --project=YOUR_PROJECT`. Use `printf` not `echo` to avoid a trailing newline.

### Azure
1. Run bootstrap. Use `gh secret set` (or repo settings) to add `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_STATE_STORAGE_ACCOUNT`, `AZURE_ACR_LOGIN_SERVER`.
2. Add `TF_VAR_ALARM_EMAIL` as a GitHub Actions variable.
3. Register providers once: `az provider register --namespace Microsoft.App --wait`.
4. Set secrets: `az keyvault secret set --vault-name mcp-dev-kv --name mcp-api-key-dev --value "..."`.
5. Add a Key Vault access policy for your local user account if you need to read secrets locally: `az keyvault set-policy --name mcp-dev-kv --object-id $(az ad signed-in-user show --query id -o tsv) --secret-permissions get list set`.

## Known rough edges

- AWS: `ecr_force_delete = true` is dev-only — set to `false` in prod
- AWS: CORS `allow_origins = ["*"]` — lock down to specific origins in prod
- GCP: `deletion_protection = false` is intentional for dev — set to `true` in prod
- Azure: `purge_protection_enabled = false` on Key Vault — enable in prod
- Azure: the `FORCE_REFRESH` env var was manually added to the live Cloud Run/Container App during debugging — remove it by re-running the deploy workflow
- All clouds: secrets are initialized to placeholder values by Terraform and must be set manually before first invocation
