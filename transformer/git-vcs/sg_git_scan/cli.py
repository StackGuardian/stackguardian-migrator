#!/usr/bin/env python3
"""
StackGuardian Migrator — git-vcs transformer CLI.

Connects to GitHub or GitLab, discovers Terraform repositories,
and generates an sg-payload.json for bulk workflow creation.

Usage:
    sg-git-scan --provider github --token ghp_xxx --org my-org
    sg-git-scan --provider gitlab --token glpat-xxx --org my-group
"""

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Any

from sg_git_scan.vcs import GitHubClient, GitLabClient, VCSError
from sg_git_scan.scanner import detect_terraform_dirs
from sg_git_scan.transform import build_payload

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)


def discover_repos(args: argparse.Namespace) -> list[dict[str, Any]]:
    """Fetch repositories from VCS provider."""
    provider = args.provider.lower()
    token = args.token

    if provider == "github":
        client = GitHubClient(token=token)
        repos = client.list_repos(org=args.org, user=args.user, max_repos=args.max_repos)
    elif provider == "gitlab":
        client = GitLabClient(token=token)
        repos = client.list_repos(group=args.org, user=args.user, max_repos=args.max_repos)
    else:
        logger.error(f"Unsupported provider: {provider}. Use 'github' or 'gitlab'.")
        sys.exit(1)

    # Filter out archived and forks by default
    if not args.include_archived:
        repos = [r for r in repos if not r.get("is_archived")]
    if not args.include_forks:
        repos = [r for r in repos if not r.get("is_fork")]

    logger.info(f"Discovered {len(repos)} repositories from {provider}")
    return repos


def scan_repos(
    repos: list[dict[str, Any]],
    provider: str,
    token: str,
) -> list[tuple[dict[str, Any], list[dict[str, Any]]]]:
    """
    For each repo, fetch the file tree and detect Terraform projects.
    Returns list of (repo, [project, ...]) tuples — only repos with TF detected.
    """
    results: list[tuple[dict[str, Any], list[dict[str, Any]]]] = []

    if provider == "github":
        client = GitHubClient(token=token)
    elif provider == "gitlab":
        client = GitLabClient(token=token)
    else:
        return results

    total = len(repos)
    for idx, repo in enumerate(repos, 1):
        name = repo["full_name"]
        logger.info(f"[{idx}/{total}] Scanning {name}...")

        try:
            if provider == "github":
                owner = repo["owner"]
                repo_name = repo["name"]
                ref = repo.get("default_branch", "HEAD")
                file_tree = client.get_file_tree(owner, repo_name, ref=ref)
            else:
                file_tree = client.get_file_tree(repo["id"], ref=repo.get("default_branch", "HEAD"))
        except VCSError as exc:
            logger.warning(f"  Could not fetch file tree for {name}: {exc}")
            continue

        if not file_tree:
            logger.debug(f"  Empty file tree for {name} — skipping")
            continue

        projects = detect_terraform_dirs(file_tree)
        if projects:
            logger.info(f"  Found {len(projects)} Terraform project(s) in {name}")
            results.append((repo, projects))
        else:
            logger.debug(f"  No Terraform detected in {name}")

    return results


def main() -> None:
    parser = argparse.ArgumentParser(
        description="StackGuardian Migrator — generate bulk workflow payload from Git repositories.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  sg-git-scan --provider github --token ghp_xxx --org my-org
  sg-git-scan --provider gitlab --token glpat-xxx --org my-group
  sg-git-scan --provider github --token ghp_xxx --org my-org --max-repos 50 --output export/sg-payload.json
        """,
    )

    # Required
    parser.add_argument("--provider", "-p", required=True, choices=["github", "gitlab"],
                        help="VCS provider (github or gitlab)")
    parser.add_argument("--token", "-t", required=True,
                        help="VCS access token (GitHub PAT or GitLab PAT)")

    # Target
    parser.add_argument("--org", "-o", default=None,
                        help="Organization (GitHub) or group (GitLab) to scan")
    parser.add_argument("--user", "-u", default=None,
                        help="User whose repos to scan (if not using --org)")

    # Filtering
    parser.add_argument("--max-repos", "-m", type=int, default=None,
                        help="Maximum repositories to scan")
    parser.add_argument("--include-archived", action="store_true", default=False,
                        help="Include archived repositories")
    parser.add_argument("--include-forks", action="store_true", default=False,
                        help="Include forked repositories")

    # SG defaults
    parser.add_argument("--wfgrp", default="imported-workflows",
                        help="Workflow group name (default: imported-workflows)")
    parser.add_argument("--vcs-auth", default="",
                        help="SG VCS integration path (e.g., /integrations/github_com)")
    parser.add_argument("--managed-state", action="store_true", default=False,
                        help="Enable SG-managed Terraform state")

    # Output
    parser.add_argument("--output", "-O", default="sg-payload.json",
                        help="Output file path (default: sg-payload.json)")
    parser.add_argument("--quiet", "-q", action="store_true", default=False,
                        help="Minimal output")
    parser.add_argument("--verbose", "-v", action="store_true", default=False,
                        help="Verbose/debug output")

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    if args.quiet:
        logging.getLogger().setLevel(logging.WARNING)

    # --- Step 1: Discover repos ---
    repos = discover_repos(args)
    if not repos:
        logger.warning("No repositories found. Check your token, org, and permissions.")
        sys.exit(0)

    # --- Step 2: Scan for Terraform ---
    repos_with_projects = scan_repos(repos, args.provider.lower(), args.token)
    if not repos_with_projects:
        logger.warning("No Terraform projects found in any repository.")
        sys.exit(0)

    total_projects = sum(len(projects) for _, projects in repos_with_projects)
    logger.info(f"Found {total_projects} Terraform project(s) across {len(repos_with_projects)} repo(s)")

    # --- Step 3: Transform to SG payload ---
    payload = build_payload(
        repos_with_projects,
        wfgrp_name=args.wfgrp,
        vcs_auth_integration=args.vcs_auth,
        managed_terraform_state=args.managed_state,
    )

    # --- Step 4: Write output ---
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2))

    logger.info(f"Generated {len(payload)} workflow(s) → {output_path}")
    logger.info(f"Use the example_payload.jsonc as a reference to edit sg-payload.json before importing")
    logger.info(f"Next step: sg-cli workflow create --bulk --org \"<ORG>\" -- {output_path}")


if __name__ == "__main__":
    main()
