# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform + GitHub Actions infrastructure for deploying MCP servers on AWS (Lambda + API Gateway). Zero idle cost — pay per request only. AWS is the first target; GCP and Azure modules are planned.

## Common commands

```bash
# Format all Terraform files (CI enforces this)
terraform fmt -recursive

# Lint (CI enforces this)
tflint --recursive

# Bootstrap (run once manually before anything else)
cd terraform/bootstrap
terraform init
terraform apply -var="github_org=YOUR_GITHUB_USERNAME" -var="budget_alert_email=YOU@example.com"

# Dev environment (after bootstrap)
cd terraform/environments/dev
terraform init -backend-config=backend.tfbackend
terraform validate
terraform plan -var="alarm_email=YOU@example.com"
```

CI runs `terraform plan` on PRs and `terraform apply` on merge to main.

## Architecture

```
Client → API Gateway (HTTP API) → Lambda (container image from ECR) → MCP server
                                        ↓ on failure
                                    SQS Dead Letter Queue
```

Resources provisioned per environment:

- **ECR** — container image repository (IMMUTABLE tags, KMS-encrypted, lifecycle: keep last 10)
- **Lambda** — container image function, X-Ray tracing, reserved concurrency cap, KMS-encrypted env vars
- **API Gateway v2** — HTTP API, `$default` catch-all route, per-route throttling
- **KMS** — single key shared across CloudWatch logs, SNS, SQS, Lambda env vars
- **SQS** — dead letter queue for failed Lambda invocations (14-day retention, KMS-encrypted)
- **CloudWatch** — log groups for Lambda and API Gateway (365-day retention, KMS-encrypted), invocation and error alarms
- **SNS** — alarm notifications topic with email subscription (KMS-encrypted)
- **IAM** — Lambda execution role with least-privilege inline policy (Secrets Manager, KMS, SQS, X-Ray)

## Module structure

```
terraform/modules/mcp-server/
├── main.tf         — terraform block, data sources, Lambda function
├── variables.tf    — all variable declarations with validation
├── iam.tf          — Lambda execution role, policies, attachments
├── kms.tf          — KMS key and alias
├── api_gateway.tf  — API Gateway v2, stage, integration, route, Lambda permission
├── monitoring.tf   — DLQ, CloudWatch log groups, alarms, SNS topic/subscription
└── outputs.tf      — all outputs
```

## Two-phase setup

1. **Bootstrap** (`terraform/bootstrap/`) — run once manually from a local machine with admin credentials. Uses local Terraform state (no backend). Creates:
   - KMS key for state bucket encryption
   - S3 bucket + DynamoDB table for remote Terraform state
   - GitHub OIDC provider (no long-lived AWS credentials needed in CI)
   - IAM role (`mcp-infra-github-actions`) that GitHub Actions assumes via OIDC
   - AWS Budget alert (configurable threshold, default $5/month)

2. **Dev environment** (`terraform/environments/dev/`) — managed by CI/CD. Uses S3 remote backend. Creates:
   - ECR repository with lifecycle policy (keep last 10 images)
   - ECR repository policy granting Lambda execution role image pull access
   - All resources via `mcp-server` module

## Security model

- **Encryption at rest** — KMS encrypts CloudWatch logs, SNS messages, SQS messages, and Lambda environment variables. A single per-environment key with explicit key policy grants only the services that need it.
- **API authentication** — `x-api-key` header checked inside the Lambda against a value stored in Secrets Manager (`mcp-infra/api-key`). API Gateway route uses `authorization_type = "NONE"` — auth is enforced in application code.
- **No long-lived credentials** — GitHub Actions uses OIDC federation to assume the `mcp-infra-github-actions` IAM role. No AWS access keys stored anywhere.
- **Blast radius caps** — `reserved_concurrent_executions` (default 10) limits Lambda parallelism; API Gateway throttling (default 10 rps / 50 burst) limits inbound rate.
- **Least privilege** — Lambda execution role has only the permissions it needs at runtime (Secrets Manager read, KMS decrypt, SQS send, X-Ray write). GitHub Actions role is scoped to the specific resources it manages.

## CI/CD

Two workflows:

- **`terraform.yml`** — triggers on pushes/PRs that touch `terraform/**`. Runs `tflint`, `checkov` (88 passing / 0 failing / 9 justified skips), `terraform plan` on PRs, `terraform apply` on merge to main.
- **`deploy-image.yml`** — triggers on pushes/PRs that touch `mcp-server/**`, or manually via `workflow_dispatch`. Builds the container image, pushes with the git SHA as tag, calls `aws lambda update-function-code`. The image URI in Terraform has `lifecycle { ignore_changes = [image_uri] }` — Terraform sets it only on creation; the deploy workflow owns it after that.

## Critical setup steps

1. Run bootstrap (see above). Add the `role_arn` output as `AWS_ROLE_ARN` in GitHub repo secrets.
2. Create Secrets Manager secrets before first Lambda invocation:
   ```bash
   aws secretsmanager create-secret --name mcp-infra/api-key --secret-string "YOUR_API_KEY"
   aws secretsmanager create-secret --name mcp-infra/github-pat --secret-string "YOUR_GITHUB_PAT"
   ```
3. For local Terraform runs, create a backend config file:
   ```bash
   cd terraform/environments/dev
   cp backend.tfbackend.example backend.tfbackend
   # Edit backend.tfbackend: set bucket = "mcp-infra-tfstate-<account-id>"
   terraform init -backend-config=backend.tfbackend
   ```
4. Confirm the SNS email subscription — AWS sends a confirmation email to `alarm_email` after first apply.

## Known rough edges

- `ecr_force_delete = true` is dev-only — set to `false` in prod to prevent accidental image deletion
- CORS `allow_origins = ["*"]` — lock down to specific origins in prod
- Provider version is `~> 5.0` (any 5.x) — tighten to a minor version range before multi-cloud expansion
