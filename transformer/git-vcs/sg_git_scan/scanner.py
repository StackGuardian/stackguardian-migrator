"""
IaC detection and Terraform parsing.

Ported from sg-onboard — detects Terraform projects in a file tree
and parses HCL to extract providers, modules, variables, backend, and version info.

Works in two modes:
  1. Remote: uses VCS API file trees (no clone needed)
  2. Local: scans cloned/local directories and parses .tf files with python-hcl2
"""

import logging
import re
from fnmatch import fnmatch
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# File-tree based detection (remote — no clone required)
# ---------------------------------------------------------------------------

TF_FILE_PATTERNS = ["*.tf", "*.tf.json"]
TFVARS_PATTERNS = ["*.tfvars", "*.tfvars.json"]
LOCK_PATTERNS = [".terraform.lock.hcl"]
EXCLUDE_DIRS = {
    ".git", ".terraform", ".terragrunt-cache", "node_modules",
    "vendor", "__pycache__", ".venv", "venv",
}


def _matches(name: str, patterns: list[str]) -> bool:
    return any(fnmatch(name, p) for p in patterns)


def detect_terraform_dirs(file_tree: list[str]) -> list[dict[str, Any]]:
    """
    From a flat file-tree list, identify directories that contain Terraform files.

    Returns a list of dicts:
        {
            "path": "infra/vpc",          # directory relative to repo root ("" for root)
            "tf_files": ["main.tf", ...],
            "has_tfvars": True,
            "has_lockfile": False,
            "tfvars_files": ["terraform.tfvars"],
        }
    """
    dirs: dict[str, dict[str, Any]] = {}

    for filepath in file_tree:
        parts = filepath.split("/")

        # skip excluded dirs
        if any(p in EXCLUDE_DIRS for p in parts):
            continue

        name = parts[-1]
        dir_path = "/".join(parts[:-1]) if len(parts) > 1 else ""

        if dir_path not in dirs:
            dirs[dir_path] = {
                "path": dir_path,
                "tf_files": [],
                "tfvars_files": [],
                "has_lockfile": False,
            }

        if _matches(name, TF_FILE_PATTERNS):
            dirs[dir_path]["tf_files"].append(name)
        elif _matches(name, TFVARS_PATTERNS):
            dirs[dir_path]["tfvars_files"].append(name)
        elif _matches(name, LOCK_PATTERNS):
            dirs[dir_path]["has_lockfile"] = True

    # only keep directories that actually have .tf files
    return [d for d in dirs.values() if d["tf_files"]]


# ---------------------------------------------------------------------------
# Local HCL parsing (requires cloned repo + python-hcl2)
# ---------------------------------------------------------------------------

def parse_terraform_dir(dir_path: Path) -> Optional[dict[str, Any]]:
    """
    Parse all .tf files in *dir_path* and return aggregated metadata.

    Returns None if the directory has no .tf files or parsing fails entirely.
    """
    try:
        import hcl2
    except ImportError:
        logger.warning("python-hcl2 not installed — skipping deep parse")
        return None

    tf_files = list(dir_path.glob("*.tf"))
    if not tf_files:
        return None

    providers: list[dict[str, Any]] = []
    modules: list[dict[str, Any]] = []
    variables: list[dict[str, Any]] = []
    outputs: list[dict[str, Any]] = []
    backend_type: Optional[str] = None
    terraform_version: Optional[str] = None
    has_backend = False

    seen_providers: set[str] = set()

    for tf_file in tf_files:
        try:
            content = tf_file.read_text(encoding="utf-8", errors="ignore")
            parsed = hcl2.loads(content)
        except Exception as exc:
            logger.debug(f"Failed to parse {tf_file}: {exc}")
            continue

        # --- providers ---
        for blk in parsed.get("provider", []):
            if isinstance(blk, dict):
                for name, cfg in blk.items():
                    if isinstance(cfg, list) and cfg:
                        cfg = cfg[0]
                    alias = cfg.get("alias") if isinstance(cfg, dict) else None
                    key = f"{name}:{alias or ''}"
                    if key not in seen_providers:
                        seen_providers.add(key)
                        providers.append({"name": name, "source": None, "version": None, "alias": alias})

        for blk in parsed.get("terraform", []):
            if not isinstance(blk, dict):
                continue

            # terraform version
            if blk.get("required_version"):
                terraform_version = blk["required_version"]

            # required_providers
            for rp in blk.get("required_providers", []):
                if isinstance(rp, dict):
                    for name, cfg in rp.items():
                        source = cfg.get("source") if isinstance(cfg, dict) else None
                        version = cfg.get("version") if isinstance(cfg, dict) else (cfg if isinstance(cfg, str) else None)
                        key = f"{name}:"
                        existing = next((p for p in providers if p["name"] == name and not p["alias"]), None)
                        if existing:
                            existing["source"] = existing["source"] or source
                            existing["version"] = existing["version"] or version
                        elif key not in seen_providers:
                            seen_providers.add(key)
                            providers.append({"name": name, "source": source, "version": version, "alias": None})

            # backend
            for be in blk.get("backend", []):
                if isinstance(be, dict):
                    for bt in be:
                        backend_type = bt
                        has_backend = True

        # --- modules ---
        for blk in parsed.get("module", []):
            if isinstance(blk, dict):
                for name, cfg in blk.items():
                    if isinstance(cfg, list) and cfg:
                        cfg = cfg[0]
                    if not isinstance(cfg, dict):
                        continue
                    modules.append({
                        "name": name,
                        "source": cfg.get("source", ""),
                        "version": cfg.get("version"),
                    })

        # --- variables ---
        for blk in parsed.get("variable", []):
            if isinstance(blk, dict):
                for name, cfg in blk.items():
                    if isinstance(cfg, list) and cfg:
                        cfg = cfg[0]
                    variables.append({
                        "name": name,
                        "type": str(cfg.get("type")) if isinstance(cfg, dict) and cfg.get("type") else None,
                        "description": cfg.get("description") if isinstance(cfg, dict) else None,
                        "default": cfg.get("default") if isinstance(cfg, dict) else None,
                    })

        # --- outputs ---
        for blk in parsed.get("output", []):
            if isinstance(blk, dict):
                for name, cfg in blk.items():
                    if isinstance(cfg, list) and cfg:
                        cfg = cfg[0]
                    outputs.append({
                        "name": name,
                        "description": cfg.get("description") if isinstance(cfg, dict) else None,
                    })

    if not providers and not modules and not variables and not outputs and not has_backend:
        # parsed OK but nothing useful extracted — still return structure
        pass

    return {
        "providers": providers,
        "modules": modules,
        "variables": variables,
        "outputs": outputs,
        "backend_type": backend_type,
        "has_backend": has_backend,
        "terraform_version": terraform_version,
        "tf_files": [f.name for f in tf_files],
    }


def infer_terraform_version(version_constraint: Optional[str]) -> str:
    """
    Convert a Terraform version constraint into a concrete version for SG workflow.

    Examples:
        ">= 1.5.0"  -> "1.5.0"
        "~> 1.3"     -> "1.3.0"
        "1.6.2"      -> "1.6.2"
        None          -> "1.5.0"  (sensible default)
    """
    if not version_constraint:
        return "1.5.0"

    # strip constraint operators
    cleaned = re.sub(r"[><=~!\s]", "", version_constraint).strip()
    if not cleaned:
        return "1.5.0"

    # pick the first version-like token
    match = re.search(r"(\d+\.\d+(?:\.\d+)?)", cleaned)
    if match:
        v = match.group(1)
        # ensure three-part version
        if v.count(".") == 1:
            v += ".0"
        return v

    return "1.5.0"


def infer_cloud_provider(providers: list[dict[str, Any]]) -> Optional[str]:
    """
    Guess the primary cloud from the Terraform providers list.

    Returns one of: "AWS_RBAC", "AZURE_STATIC", "GCP_STATIC", or None.
    """
    provider_names = {p["name"].lower() for p in providers}
    source_names = {(p.get("source") or "").lower() for p in providers}
    all_names = provider_names | source_names

    if any("aws" in n for n in all_names):
        return "AWS_RBAC"
    if any("azurerm" in n or "azure" in n for n in all_names):
        return "AZURE_STATIC"
    if any("google" in n or "gcp" in n for n in all_names):
        return "GCP_STATIC"
    return None
