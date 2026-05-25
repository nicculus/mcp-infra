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
terraform apply \
  -var="github_org=YOUR_GITHUB_USERNAME" \
  -var="budget_alert_email=YOUR_EMAIL"
```

This creates:
- S3 bucket + DynamoDB table for remote Terraform state
- GitHub OIDC provider in AWS (no stored credentials needed)
- IAM role (`mcp-infra-github-actions`) that GitHub Actions can assume
- AWS Budget alert — email when monthly spend exceeds 80% of $5

> **Note:** If you see `EntityAlreadyExists` for the OIDC provider, you already have one from a previous project. Run:
> ```bash
> terraform import aws_iam_openid_connect_provider.github \
>   arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
> terraform apply -var="github_org=YOUR_GITHUB_USERNAME"
> ```

Save the outputs — you'll need them in the next step.

### 2. Wire up the pipeline

**Add a GitHub Actions secret** in your repo settings → Secrets and variables → Actions:

| Name | Value |
|------|-------|
| `AWS_ROLE_ARN` | `role_arn` output from bootstrap |

**For local Terraform runs**, create a backend config file (gitignored):

```bash
cd terraform/environments/dev
cp backend.tfbackend.example backend.tfbackend
# Edit backend.tfbackend — set bucket to the state_bucket output from bootstrap
terraform init -backend-config=backend.tfbackend
```

> CI derives the bucket name automatically from your AWS account ID — no manual config needed there.

### 3. Set the alarm email

The dev environment needs an email for CloudWatch alerts. Add a GitHub Actions variable in your repo settings → Secrets and variables → Actions → Variables:

| Name | Value |
|------|-------|
| `TF_VAR_ALARM_EMAIL` | Your email address |

### 4. Push and go

```bash
git add . && git commit -m "initial infra" && git push
```

GitHub Actions will run `terraform plan` automatically. Merge to main to apply.

> **Note:** After the first apply, AWS will send a confirmation email for the CloudWatch alarm SNS subscription — click **Confirm subscription** or alerts won't fire.

### 5. Push an image

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

## Authentication

The endpoint requires an `x-api-key` header on every request. The key is stored in AWS Secrets Manager (`mcp-infra/api-key`) and never appears in logs or Terraform state.

Responses are [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events). Pipe through `grep` and `sed` to extract the JSON:

```bash
curl -s -X POST https://YOUR_ENDPOINT/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' \
  | grep '^data:' | sed 's/^data: //'
```

Example response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "name": "get_repo_summary",
        "description": "Get metadata about a GitHub repository (stars, language, description, topics).",
        "inputSchema": {
          "properties": { "repo_url": { "type": "string" } },
          "required": ["repo_url"],
          "type": "object"
        }
      },
      {
        "name": "get_repo_readme",
        "description": "Fetch the README content of a GitHub repository.",
        "inputSchema": {
          "properties": { "repo_url": { "type": "string" } },
          "required": ["repo_url"],
          "type": "object"
        }
      }
    ]
  }
}
```

Call a tool:

```bash
curl -s -X POST https://YOUR_ENDPOINT/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"get_repo_summary","arguments":{"repo_url":"anthropics/anthropic-sdk-python"}}}' \
  | grep '^data:' | sed 's/^data: //'
```

Example response:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [{ "type": "text", "text": "..." }],
    "structuredContent": {
      "name": "anthropics/anthropic-sdk-python",
      "description": "The official Python library for the Anthropic API",
      "stars": 3100,
      "forks": 312,
      "language": "Python",
      "topics": ["anthropic", "claude", "llm"],
      "url": "https://github.com/anthropics/anthropic-sdk-python",
      "created_at": "2023-07-19T17:00:00Z",
      "updated_at": "2026-05-20T00:00:00Z"
    },
    "isError": false
  }
}
```

To provision the key before deploying:

```bash
aws secretsmanager create-secret \
  --name mcp-infra/api-key \
  --secret-string "$(openssl rand -hex 32)" \
  --region us-east-1
```

The GitHub PAT (for authenticated GitHub API calls, 5,000 req/hr vs 60 unauthenticated) is stored the same way. Create one at GitHub → Settings → Developer settings → Personal access tokens, scoped to **Public Repositories (read-only)**, then store it:

```bash
aws secretsmanager create-secret \
  --name mcp-infra/github-pat \
  --secret-string "YOUR_PAT" \
  --region us-east-1
```

Both secrets are fetched once per Lambda cold start and cached in memory.

## Cost protection and alerting

| Layer | What it does |
|-------|-------------|
| API Gateway throttling | 429s after 10 req/sec sustained / 50 burst — caps Lambda invocations |
| CloudWatch alarms | Email within 5 minutes if invocations > 1,000 or errors > 10 in a 5-minute window |
| AWS Budget alert | Email when monthly spend hits 80% of $5 |

> After the first Terraform apply, confirm the SNS subscription email from AWS or alerts won't fire.

## Known limitations / production hardening

- [ ] API Gateway CORS allows `*` origins — restrict for production
- [ ] ECR `force_delete = true` is dev-only — remove before creating a prod environment
- [ ] Add a prod environment (`terraform/environments/prod/`) when ready

## License

MIT
