import base64
import re

import httpx
from fastmcp import FastMCP

mcp = FastMCP("github-repo-explorer")

GITHUB_HEADERS = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}


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
            headers=GITHUB_HEADERS,
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
            headers=GITHUB_HEADERS,
        )
        r.raise_for_status()
        data = r.json()
    return base64.b64decode(data["content"]).decode("utf-8")


# Lambda entrypoint
handler = mcp.lambda_handler()
