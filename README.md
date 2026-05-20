# Serverless MCP Server Infrastructure

Deploy any [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server on AWS with zero idle cost, full CI/CD, and no long-lived AWS credentials — using Terraform, Lambda, and GitHub Actions OIDC.

**Cost at rest: $0.** You pay only when your MCP server receives requests.

## Why this exists

Running an MCP server in the cloud usually means paying for an always-on container or VM. This setup uses AWS Lambda behind API Gateway — you pay per request (~$1 per million) and nothing when idle. The full pipeline is automated: `terraform plan` runs on every PR, `terraform apply` runs on merge to main, and AWS credentials are never stored as long-lived secrets.

## Architecture

```
Claude / MCP Client
        │
        ▼
API Gateway (HTTP API)
        │
        ▼
Lambda Function (container image from ECR)
        │
        ▼
Your MCP server code
```

**Two-phase Terraform setup:**

- **Bootstrap** — run once from your local machine. Creates the S3 state bucket, DynamoDB lock table, and GitHub OIDC trust so CI can assume an AWS role without storing credentials.
- **Dev environment** — managed entirely by CI after that. Creates ECR, Lambda, API Gateway, IAM, and CloudWatch log groups.

## Prerequisites

- AWS account with admin access
- [Terraform >= 1.12](https://developer.hashicorp.com/terraform/install) (`brew install hashicorp/tap/terraform`)
- AWS CLI configured (`aws configure`)
- GitHub repo (public or private)
- Docker (for building your MCP server image)

## Setup

### 1. Bootstrap (one-time, from your machine)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="github_org=YOUR_GITHUB_USERNAME"
```

This creates:
- S3 bucket + DynamoDB table for remote Terraform state
- GitHub OIDC provider in AWS (no stored credentials needed)
- IAM role (`mcp-infra-github-actions`) that GitHub Actions can assume

> **Note:** If you see `EntityAlreadyExists` for the OIDC provider, you already have one from a previous project. Run:
> ```bash
> terraform import aws_iam_openid_connect_provider.github \
>   arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
> terraform apply -var="github_org=YOUR_GITHUB_USERNAME"
> ```

Save the outputs — you'll need them in the next step.

### 2. Wire up the pipeline

**Update the backend config** in `terraform/environments/dev/main.tf`:

```hcl
backend "s3" {
  bucket = "YOUR_STATE_BUCKET"   # state_bucket output from bootstrap
  ...
}
```

**Add a GitHub Actions secret** in your repo settings → Secrets and variables → Actions:

| Name | Value |
|------|-------|
| `AWS_ROLE_ARN` | `role_arn` output from bootstrap |

### 3. Push and go

```bash
git add . && git commit -m "initial infra" && git push
```

GitHub Actions will run `terraform plan` automatically. Merge to main to apply.

### 4. Push an image

The Lambda function needs a container image in ECR before it can be created. The `deploy-image` workflow handles this automatically on push to `main` when files under `mcp-server/` change. Or push manually:

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

docker build -t YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mcp-server:latest mcp-server/
docker push YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mcp-server:latest
```

After the image is pushed, re-run the Terraform workflow to finish creating the Lambda function.

## Repo structure

```
├── .github/workflows/
│   ├── terraform.yml       # Plan on PR, apply on merge to main
│   └── deploy-image.yml    # Build + push container image to ECR
├── mcp-server/
│   ├── Dockerfile          # Lambda container image
│   ├── requirements.txt
│   └── server.py           # FastMCP server (replace with your own)
└── terraform/
    ├── bootstrap/           # Run once manually
    │   └── main.tf          # OIDC provider, state bucket, IAM role
    ├── environments/
    │   └── dev/
    │       └── main.tf      # ECR repository + mcp-server module
    └── modules/
        └── mcp-server/
            └── main.tf      # Lambda, API Gateway, IAM, CloudWatch logs
```

## Deploying your own MCP server

Replace `mcp-server/server.py` (and the `Dockerfile` if needed) with your MCP server implementation. Any push to `main` that touches `mcp-server/` will rebuild and push the image, then Lambda will pick it up on the next invocation.

The Lambda execution role has `AWSLambdaBasicExecutionRole` only. Extend it in `terraform/modules/mcp-server/main.tf` for additional AWS access (DynamoDB, S3, Secrets Manager, etc.).

## Cost estimate

| Resource | Idle | Per-request |
|----------|------|-------------|
| API Gateway | $0 | $1.00 / million requests |
| Lambda (512 MB) | $0 | ~$0.20 / million invocations |
| ECR | ~$0.10 / GB / month | — |
| CloudWatch Logs | $0 | ~$0.50 / GB ingested |

A lightly-used personal MCP server costs effectively nothing.

## Known limitations / production hardening

- [ ] GitHub Actions IAM role has `AdministratorAccess` — scope it down once you know what Terraform needs
- [ ] API Gateway CORS allows `*` origins — restrict for production
- [ ] No authentication on the endpoint — add an API key, IAM auth, or Lambda authorizer
- [ ] ECR `force_delete = true` is dev-only — remove before creating a prod environment
- [ ] Add a prod environment (`terraform/environments/prod/`) when ready

## License

MIT
