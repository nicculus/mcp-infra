import base64
import os
import re

import boto3
import httpx
from fastmcp import FastMCP
from mangum import Mangum
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse

mcp = FastMCP("github-repo-explorer")

_sm = boto3.client("secretsmanager")


def _get_secret(env_var: str) -> str:
    name = os.environ.get(env_var, "")
    if not name:
        return ""
    return _sm.get_secret_value(SecretId=name).get("SecretString", "")


# Fetched once per container cold start
_API_KEY = _get_secret("API_KEY_SECRET")
_GITHUB_PAT = _get_secret("GITHUB_PAT_SECRET")


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


_app = Starlette(routes=_mcp_app.routes, lifespan=_mcp_app.lifespan)
_app.middleware_stack = _auth_middleware
handler = Mangum(_app, lifespan="on")
