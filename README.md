# MCP Server Infrastructure

Terraform + GitHub Actions pipeline for deploying MCP servers on AWS using Lambda + API Gateway. Zero idle cost.

## Prerequisites

- AWS account with admin access
- Terraform >= 1.12 installed locally (`brew install terraform`)
- GitHub repo created
- AWS CLI configured (`aws configure`)
- Docker (for building Lambda container images)

## Setup Order

### 1. Bootstrap (one-time, from your machine)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="github_org=YOUR_GITHUB_USERNAME"
```

This creates:
- S3 bucket + DynamoDB table for Terraform state
- GitHub OIDC provider in AWS
- IAM role for GitHub Actions

Save the outputs — you'll need them next.

### 2. Configure the pipeline

- Copy the `role_arn` output → add as `AWS_ROLE_ARN` secret in GitHub repo settings
- Copy the `state_bucket` output → replace `REPLACE-WITH-BOOTSTRAP-OUTPUT` in
  `terraform/environments/dev/main.tf`

### 3. Push and go

```bash
git add . && git commit -m "initial infra" && git push
```

The pipeline runs `terraform plan` on PRs and `terraform apply` on merge to main.

## Architecture

```
Client → API Gateway (HTTP API) → Lambda (container image) → your MCP server code
```

No VPC, no ALB, no idle costs. You pay per request.

## Structure

```
├── .github/workflows/
│   └── terraform.yml          # CI/CD pipeline
├── terraform/
│   ├── bootstrap/             # Run once manually
│   │   └── main.tf            # OIDC, state bucket, locks
│   ├── environments/
│   │   └── dev/
│   │       └── main.tf        # ECR + MCP server module
│   └── modules/
│       └── mcp-server/
│           └── main.tf        # Lambda, API Gateway, IAM, logs
```

## Cost Estimate (dev)

| Resource      | Idle Cost | Per-request          |
|---------------|-----------|----------------------|
| API Gateway   | $0        | $1 per million reqs  |
| Lambda        | $0        | ~$0.20 per 1M invocations (512MB) |
| ECR           | ~$0.10/GB/month | —             |
| CloudWatch    | minimal   | —                    |

## Next Steps

- [ ] Build an MCP server container image and push to ECR
- [ ] Add a custom domain (Route53 + ACM cert)
- [ ] Add auth (API key, IAM auth, or Lambda authorizer)
- [ ] Add Secrets Manager for API keys / tokens
- [ ] Scope down the GitHub Actions IAM role from AdministratorAccess
- [ ] Add a prod environment
