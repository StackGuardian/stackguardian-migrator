"""
VCS clients for GitHub and GitLab.

Lightweight repo-listing clients ported from sg-onboard.
Only fetches repository metadata — no cloning logic here.
"""

import logging
import time
import urllib.parse
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)

GITHUB_API_URL = "https://api.github.com"
GITLAB_API_URL = "https://gitlab.com/api/v4"


class VCSError(Exception):
    def __init__(self, message: str, status_code: Optional[int] = None):
        super().__init__(message)
        self.status_code = status_code


class RateLimitError(VCSError):
    def __init__(self, message: str, retry_after: int = 0, **kwargs):
        super().__init__(message, **kwargs)
        self.retry_after = retry_after


# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

class GitHubClient:
    """Minimal GitHub API client for listing org/user repositories."""

    def __init__(self, token: str, api_url: str = GITHUB_API_URL):
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _headers(self) -> dict[str, str]:
        return {
            "Accept": "application/vnd.github.v3+json",
            "Authorization": f"token {self.token}",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def _handle(self, resp: httpx.Response) -> Any:
        if resp.status_code == 401:
            raise VCSError("GitHub authentication failed", 401)
        if resp.status_code == 403:
            remaining = int(resp.headers.get("X-RateLimit-Remaining", "1"))
            if remaining == 0:
                reset_ts = int(resp.headers.get("X-RateLimit-Reset", "0"))
                wait = max(0, reset_ts - int(time.time()))
                raise RateLimitError(f"Rate limit exceeded, resets in {wait}s", retry_after=wait, status_code=403)
            raise VCSError("GitHub access forbidden", 403)
        if resp.status_code == 404:
            raise VCSError("Not found", 404)
        if resp.status_code >= 400:
            raise VCSError(f"GitHub API error: {resp.text}", resp.status_code)
        return resp.json()

    def _next_page(self, link_header: str) -> Optional[int]:
        if not link_header:
            return None
        for part in link_header.split(","):
            if 'rel="next"' in part:
                try:
                    url_part = part.split(";")[0].strip().strip("<>")
                    params = urllib.parse.parse_qs(urllib.parse.urlparse(url_part).query)
                    if "page" in params:
                        return int(params["page"][0])
                except (ValueError, IndexError):
                    pass
        return None

    def list_repos(
        self,
        org: Optional[str] = None,
        user: Optional[str] = None,
        max_repos: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        """List repositories for an org, user, or the authenticated user."""
        repos: list[dict[str, Any]] = []
        page = 1
        per_page = 100

        with httpx.Client(base_url=self.api_url, headers=self._headers(), timeout=30.0) as client:
            while True:
                params: dict[str, Any] = {"per_page": per_page, "page": page}
                if org:
                    params["type"] = "all"
                    resp = client.get(f"/orgs/{org}/repos", params=params)
                elif user:
                    params["type"] = "all"
                    resp = client.get(f"/users/{user}/repos", params=params)
                else:
                    params["visibility"] = "all"
                    params["affiliation"] = "owner,collaborator,organization_member"
                    resp = client.get("/user/repos", params=params)

                data = self._handle(resp)
                if not data:
                    break

                for r in data:
                    repos.append(self._format(r))

                if max_repos and len(repos) >= max_repos:
                    repos = repos[:max_repos]
                    break

                next_page = self._next_page(resp.headers.get("Link", ""))
                if next_page is None:
                    break
                page = next_page

        return repos

    def get_file_tree(self, owner: str, repo: str, ref: str = "HEAD") -> list[str]:
        """Fetch the full file tree of a repo via the Git Trees API (recursive)."""
        with httpx.Client(base_url=self.api_url, headers=self._headers(), timeout=30.0) as client:
            resp = client.get(f"/repos/{owner}/{repo}/git/trees/{ref}", params={"recursive": "1"})
            if resp.status_code == 404 or resp.status_code == 409:
                return []
            data = self._handle(resp)
            return [item["path"] for item in data.get("tree", []) if item.get("type") == "blob"]

    @staticmethod
    def _format(r: dict[str, Any]) -> dict[str, Any]:
        owner = r.get("owner", {})
        return {
            "id": str(r.get("id")),
            "name": r.get("name", ""),
            "full_name": r.get("full_name", ""),
            "url": r.get("html_url", ""),
            "clone_url": r.get("clone_url", ""),
            "owner": owner.get("login", ""),
            "default_branch": r.get("default_branch", "main"),
            "is_private": r.get("private", True),
            "is_archived": r.get("archived", False),
            "is_fork": r.get("fork", False),
            "description": r.get("description"),
            "topics": r.get("topics", []),
            "language": r.get("language"),
            "provider": "GITHUB_COM",
        }


# ---------------------------------------------------------------------------
# GitLab
# ---------------------------------------------------------------------------

class GitLabClient:
    """Minimal GitLab API client for listing group/user projects."""

    def __init__(self, token: str, api_url: str = GITLAB_API_URL):
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _headers(self) -> dict[str, str]:
        return {
            "Accept": "application/json",
            "PRIVATE-TOKEN": self.token,
        }

    def _handle(self, resp: httpx.Response) -> Any:
        if resp.status_code == 401:
            raise VCSError("GitLab authentication failed", 401)
        if resp.status_code == 403:
            raise VCSError("GitLab access forbidden", 403)
        if resp.status_code == 404:
            raise VCSError("Not found", 404)
        if resp.status_code >= 400:
            raise VCSError(f"GitLab API error: {resp.text}", resp.status_code)
        return resp.json()

    def _next_page(self, headers: httpx.Headers) -> Optional[int]:
        np = headers.get("X-Next-Page")
        if np and np.strip():
            try:
                return int(np)
            except ValueError:
                pass
        return None

    def list_repos(
        self,
        group: Optional[str] = None,
        user: Optional[str] = None,
        max_repos: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        repos: list[dict[str, Any]] = []
        page = 1
        per_page = 100

        with httpx.Client(base_url=self.api_url, headers=self._headers(), timeout=30.0) as client:
            while True:
                params: dict[str, Any] = {"per_page": per_page, "page": page, "order_by": "last_activity_at", "sort": "desc"}
                if group:
                    encoded = urllib.parse.quote(group, safe="")
                    params["include_subgroups"] = "true"
                    resp = client.get(f"/groups/{encoded}/projects", params=params)
                elif user:
                    resp = client.get(f"/users/{user}/projects", params=params)
                else:
                    params["membership"] = "true"
                    resp = client.get("/projects", params=params)

                data = self._handle(resp)
                if not data:
                    break

                for p in data:
                    repos.append(self._format(p))

                if max_repos and len(repos) >= max_repos:
                    repos = repos[:max_repos]
                    break

                next_page = self._next_page(resp.headers)
                if next_page is None:
                    break
                page = next_page

        return repos

    def get_file_tree(self, project_id: str, ref: str = "HEAD") -> list[str]:
        """Fetch the file tree of a GitLab project via the Repository Tree API."""
        files: list[str] = []
        page = 1
        with httpx.Client(base_url=self.api_url, headers=self._headers(), timeout=30.0) as client:
            while True:
                resp = client.get(
                    f"/projects/{project_id}/repository/tree",
                    params={"ref": ref, "recursive": "true", "per_page": 100, "page": page},
                )
                if resp.status_code in (404, 409):
                    return []
                data = self._handle(resp)
                if not data:
                    break
                files.extend(item["path"] for item in data if item.get("type") == "blob")
                next_page = self._next_page(resp.headers)
                if next_page is None:
                    break
                page = next_page
        return files

    @staticmethod
    def _format(p: dict[str, Any]) -> dict[str, Any]:
        ns = p.get("namespace", {})
        path_with_ns = p.get("path_with_namespace", "")
        parts = path_with_ns.rsplit("/", 1)
        owner = parts[0] if len(parts) > 1 else ns.get("path", "")
        return {
            "id": str(p.get("id")),
            "name": p.get("name", ""),
            "full_name": path_with_ns,
            "url": p.get("web_url", ""),
            "clone_url": p.get("http_url_to_repo", ""),
            "owner": owner,
            "default_branch": p.get("default_branch", "main"),
            "is_private": p.get("visibility") == "private",
            "is_archived": p.get("archived", False),
            "is_fork": bool(p.get("forked_from_project")),
            "description": p.get("description"),
            "topics": p.get("topics", []) or p.get("tag_list", []),
            "language": None,
            "provider": "GITLAB_COM",
        }
