"""Unit tests for the MCP server."""
import base64
import json
import os
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
import respx
from starlette.testclient import TestClient


# Patch cloud_secrets before importing server so module-level _API_KEY/_GITHUB_PAT
# resolve from env vars rather than hitting a cloud secret service.
with patch("cloud_secrets.get_secret", side_effect=lambda var: os.environ.get(var, "")):
    import sys
    sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
    from server import _parse_repo, _github_headers, get_server_info, get_config, analyze_endpoint, troubleshoot_deployment, _auth_middleware, app


# --- _parse_repo -------------------------------------------------------------

class TestParseRepo:
    def test_full_https_url(self):
        assert _parse_repo("https://github.com/owner/repo") == ("owner", "repo")

    def test_url_with_git_suffix(self):
        assert _parse_repo("https://github.com/owner/repo.git") == ("owner", "repo")

    def test_url_with_trailing_slash(self):
        assert _parse_repo("https://github.com/owner/repo/") == ("owner", "repo")

    def test_url_with_subpath(self):
        assert _parse_repo("https://github.com/owner/repo/tree/main") == ("owner", "repo")

    def test_owner_slash_repo_shorthand(self):
        assert _parse_repo("owner/repo") == ("owner", "repo")

    def test_invalid_raises_value_error(self):
        with pytest.raises(ValueError, match="Could not parse"):
            _parse_repo("not-a-repo")

    def test_single_segment_raises_value_error(self):
        with pytest.raises(ValueError):
            _parse_repo("onlyone")


# --- _github_headers ---------------------------------------------------------

class TestGithubHeaders:
    def test_base_headers_always_present(self):
        with patch("server._GITHUB_PAT", ""):
            headers = _github_headers()
        assert headers["Accept"] == "application/vnd.github+json"
        assert headers["X-GitHub-Api-Version"] == "2022-11-28"
        assert "Authorization" not in headers

    def test_authorization_added_when_pat_set(self):
        with patch("server._GITHUB_PAT", "my-pat"):
            headers = _github_headers()
        assert headers["Authorization"] == "Bearer my-pat"


# --- get_repo_summary --------------------------------------------------------

class TestGetRepoSummary:
    @respx.mock
    @pytest.mark.asyncio
    async def test_returns_expected_fields(self):
        from server import get_repo_summary
        payload = {
            "full_name": "owner/repo",
            "description": "A test repo",
            "stargazers_count": 42,
            "forks_count": 7,
            "language": "Python",
            "topics": ["mcp", "demo"],
            "html_url": "https://github.com/owner/repo",
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2024-06-01T00:00:00Z",
        }
        respx.get("https://api.github.com/repos/owner/repo").mock(
            return_value=httpx.Response(200, json=payload)
        )
        result = await get_repo_summary("https://github.com/owner/repo")
        assert result["name"] == "owner/repo"
        assert result["stars"] == 42
        assert result["forks"] == 7
        assert result["language"] == "Python"
        assert result["topics"] == ["mcp", "demo"]

    @respx.mock
    @pytest.mark.asyncio
    async def test_raises_on_http_error(self):
        from server import get_repo_summary
        respx.get("https://api.github.com/repos/owner/repo").mock(
            return_value=httpx.Response(404)
        )
        with pytest.raises(httpx.HTTPStatusError):
            await get_repo_summary("https://github.com/owner/repo")


# --- get_repo_readme ---------------------------------------------------------

class TestGetRepoReadme:
    @respx.mock
    @pytest.mark.asyncio
    async def test_decodes_base64_content(self):
        from server import get_repo_readme
        content = base64.b64encode(b"# Hello World\n").decode()
        respx.get("https://api.github.com/repos/owner/repo/readme").mock(
            return_value=httpx.Response(200, json={"content": content})
        )
        result = await get_repo_readme("https://github.com/owner/repo")
        assert result == "# Hello World\n"

    @respx.mock
    @pytest.mark.asyncio
    async def test_raises_on_http_error(self):
        from server import get_repo_readme
        respx.get("https://api.github.com/repos/owner/repo/readme").mock(
            return_value=httpx.Response(404)
        )
        with pytest.raises(httpx.HTTPStatusError):
            await get_repo_readme("https://github.com/owner/repo")


# --- resources ---------------------------------------------------------------

class TestGetServerInfo:
    def test_returns_valid_json(self):
        result = json.loads(get_server_info())
        assert result["name"] == "mcp-infra-demo"
        assert result["version"] == "0.1.0"
        assert "tools" in result["capabilities"]

    def test_cloud_defaults_to_local(self, monkeypatch):
        monkeypatch.delenv("CLOUD_PROVIDER", raising=False)
        result = json.loads(get_server_info())
        assert result["cloud"] == "local"

    def test_cloud_reflects_env_var(self, monkeypatch):
        monkeypatch.setenv("CLOUD_PROVIDER", "aws")
        result = json.loads(get_server_info())
        assert result["cloud"] == "aws"


class TestGetConfig:
    def test_known_key_returns_value(self, monkeypatch):
        monkeypatch.setenv("AWS_REGION", "us-west-2")
        result = json.loads(get_config("region"))
        assert result["key"] == "region"
        assert result["value"] == "us-west-2"

    def test_runtime_key(self):
        result = json.loads(get_config("runtime"))
        assert result["value"] == "python"

    def test_framework_key(self):
        result = json.loads(get_config("framework"))
        assert result["value"] == "fastmcp"

    def test_unknown_key_returns_error(self):
        result = json.loads(get_config("nonexistent"))
        assert "error" in result
        assert "available_keys" in result

    def test_unknown_key_lists_available(self):
        result = json.loads(get_config("nonexistent"))
        assert set(result["available_keys"]) == {"region", "runtime", "framework"}


# --- prompts -----------------------------------------------------------------

class TestAnalyzeEndpoint:
    def test_contains_url_and_method(self):
        result = analyze_endpoint("https://api.example.com/users", "POST")
        assert "POST" in result
        assert "https://api.example.com/users" in result

    def test_default_method_is_get(self):
        result = analyze_endpoint("https://api.example.com/users")
        assert "GET" in result

    def test_contains_expected_sections(self):
        result = analyze_endpoint("https://api.example.com/users")
        assert "Security considerations" in result
        assert "Potential error cases" in result


class TestTroubleshootDeployment:
    def test_contains_cloud_and_service(self):
        result = troubleshoot_deployment("gcp", "cloud-run")
        assert "gcp" in result
        assert "cloud-run" in result

    def test_error_message_included_when_provided(self):
        result = troubleshoot_deployment("aws", "lambda", "Function timed out")
        assert "Function timed out" in result

    def test_error_message_omitted_when_empty(self):
        result = troubleshoot_deployment("aws", "lambda")
        assert "Error Message" not in result

    def test_contains_expected_sections(self):
        result = troubleshoot_deployment("azure", "container-apps")
        assert "Common causes" in result
        assert "Prevention strategies" in result


# --- auth middleware ---------------------------------------------------------

class TestAuthMiddleware:
    def setup_method(self):
        self.client = TestClient(app, raise_server_exceptions=False)

    def test_valid_key_passes(self):
        with patch("server._API_KEY", "test-key"):
            r = self.client.post("/mcp", headers={"x-api-key": "test-key"}, json={})
        assert r.status_code != 401

    def test_missing_key_returns_401(self):
        with patch("server._API_KEY", "test-key"):
            r = self.client.post("/mcp", json={})
        assert r.status_code == 401
        assert r.json()["error"] == "Unauthorized"

    def test_wrong_key_returns_401(self):
        with patch("server._API_KEY", "test-key"):
            r = self.client.post("/mcp", headers={"x-api-key": "wrong-key"}, json={})
        assert r.status_code == 401

    def test_no_auth_required_when_api_key_unset(self):
        with patch("server._API_KEY", ""):
            r = self.client.post("/mcp", json={})
        assert r.status_code != 401
