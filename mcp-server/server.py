import base64
import os
import re

import httpx
from fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse

from cloud_secrets import get_secret

mcp = FastMCP("github-repo-explorer")

# Fetched once per container cold start
_API_KEY = get_secret("API_KEY_SECRET")
_GITHUB_PAT = get_secret("GITHUB_PAT_SECRET")


def _github_headers() -> dict:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if _GITHUB_PAT:
        headers["Authorization"] = f"Bearer {_GITHUB_PAT}"
    return headers


def _parse_repo(repo_url: str) -> tuple[str, str]:
    match = re.search(r"github\.com/([^/]+)/([^/]+?)(?:\.git)?(?:/.*)?$", repo_url)
    if match:
        return match.group(1), match.group(2)
    parts = repo_url.strip("/").split("/")
    if len(parts) == 2:
        return parts[0], parts[1]
    raise ValueError(f"Could not parse GitHub repo from: {repo_url}")


@mcp.tool()
async def get_repo_summary(repo_url: str) -> dict:
    """Get metadata about a GitHub repository (stars, language, description, topics)."""
    owner, repo = _parse_repo(repo_url)
    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"https://api.github.com/repos/{owner}/{repo}",
            headers=_github_headers(),
        )
        r.raise_for_status()
        data = r.json()
    return {
        "name": data["full_name"],
        "description": data.get("description"),
        "stars": data["stargazers_count"],
        "forks": data["forks_count"],
        "language": data.get("language"),
        "topics": data.get("topics", []),
        "url": data["html_url"],
        "created_at": data["created_at"],
        "updated_at": data["updated_at"],
    }


@mcp.tool()
async def get_repo_readme(repo_url: str) -> str:
    """Fetch the README content of a GitHub repository."""
    owner, repo = _parse_repo(repo_url)
    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"https://api.github.com/repos/{owner}/{repo}/readme",
            headers=_github_headers(),
        )
        r.raise_for_status()
        data = r.json()
    return base64.b64decode(data["content"]).decode("utf-8")


# --- Resources ---------------------------------------------------------------

@mcp.resource("server://info")
def get_server_info() -> str:
    """Server metadata including version, cloud provider, and capabilities."""
    import json
    return json.dumps({
        "name": "mcp-infra-demo",
        "version": "0.1.0",
        "cloud": os.environ.get("CLOUD_PROVIDER", "local"),
        "capabilities": ["tools", "resources", "prompts"],
        "transport": "streamable-http",
    })


@mcp.resource("config://{key}")
def get_config(key: str) -> str:
    """Read a configuration value by key. Demo resource with URI template."""
    import json
    config = {
        "region": os.environ.get("AWS_REGION", os.environ.get("AZURE_REGION", os.environ.get("GCP_REGION", "local"))),
        "runtime": "python",
        "framework": "fastmcp",
    }
    value = config.get(key)
    if value is None:
        return json.dumps({"error": f"Unknown config key: {key}", "available_keys": list(config.keys())})
    return json.dumps({"key": key, "value": value})


# --- Prompts -----------------------------------------------------------------

@mcp.prompt()
def analyze_endpoint(url: str, method: str = "GET") -> str:
    """Generate a prompt for analyzing an API endpoint's behavior and response."""
    return f"""Analyze the following API endpoint and provide a summary of:
1. What the endpoint does based on its URL pattern
2. Expected request format for {method} {url}
3. Likely response structure
4. Potential error cases
5. Security considerations

Endpoint: {method} {url}"""


@mcp.prompt()
def troubleshoot_deployment(cloud: str, service: str, error_message: str = "") -> str:
    """Generate a troubleshooting prompt for a cloud deployment issue."""
    base = f"""Help troubleshoot a deployment issue on {cloud}.

Service: {service}
Cloud Provider: {cloud}"""
    if error_message:
        base += f"\nError Message: {error_message}"
    base += """

Please provide:
1. Common causes for this type of issue
2. Diagnostic steps to identify the root cause
3. Recommended fixes in order of likelihood
4. Prevention strategies for the future"""
    return base


# --- Auth middleware ---------------------------------------------------------

_mcp_app = mcp.http_app(stateless_http=True)


async def _auth_middleware(scope, receive, send):
    if scope["type"] == "http" and _API_KEY:
        request = Request(scope, receive)
        if request.headers.get("x-api-key") != _API_KEY:
            response = JSONResponse({"error": "Unauthorized"}, status_code=401)
            await response(scope, receive, send)
            return
    await _mcp_app(scope, receive, send)


app = Starlette(routes=_mcp_app.routes, lifespan=_mcp_app.lifespan)
app.middleware_stack = _auth_middleware
