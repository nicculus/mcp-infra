# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform + GitHub Actions infrastructure for deploying MCP servers on AWS (Lambda + API Gateway). Zero idle cost — pay per request only.

## Common commands

```bash
# Format all Terraform files (CI enforces this)
terraform fmt -recursive

# Bootstrap (run once manually before anything else)
cd terraform/bootstrap
terraform init
terraform apply -var="github_org=YOUR_GITHUB_USERNAME"

# Dev environment (after bootstrap)
cd terraform/environments/dev
terraform init
terraform plan
terraform validate
```

CI runs `terraform plan` on PRs and `terraform apply` on merge to main.

## Architecture

```
Client → API Gateway (HTTP API) → Lambda (container image from ECR) → MCP server
```

**Two-phase setup:**

1. **Bootstrap** (`terraform/bootstrap/`) — run once manually from a local machine. Uses local Terraform state (no backend). Creates:
   - S3 bucket + DynamoDB table for remote state
   - GitHub OIDC provider (no long-lived AWS credentials needed in CI)
   - IAM role (`mcp-infra-github-actions`) that GitHub Actions assumes

2. **Dev environment** (`terraform/environments/dev/`) — managed by CI/CD. Uses S3 remote backend. Creates:
   - ECR repository for MCP server container images
   - Calls `mcp-server` module

**`mcp-server` module** (`terraform/modules/mcp-server/`) provisions:
- Lambda function (container image, `image/package_type`)
- API Gateway v2 (HTTP API with `$default` catch-all route)
- IAM execution role (basic execution only — extend inline for DynamoDB, S3, Secrets Manager, etc.)
- CloudWatch log groups for Lambda and API Gateway (14-day retention)

An alternative Lambda Function URL approach is commented out in the module as a simpler option if API Gateway features aren't needed.

## Critical setup step

After running bootstrap, you must manually replace the placeholder in `terraform/environments/dev/main.tf`:

```hcl
bucket = "REPLACE-WITH-BOOTSTRAP-OUTPUT"  # use state_bucket output from bootstrap
```

And add the `role_arn` bootstrap output as the `AWS_ROLE_ARN` secret in GitHub repo settings.

## Known rough edges to address

- GitHub Actions IAM role has `AdministratorAccess` — scope it down once the required permissions are known
- `force_delete = true` on the ECR repo is dev-only; remove for prod
- CORS on API Gateway allows `*` origins — lock down for prod
- No auth on the API Gateway endpoint yet (options: API key, IAM auth, Lambda authorizer)
