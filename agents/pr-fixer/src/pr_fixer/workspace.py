"""Per-repo working clones the agent operates in.

A persistent clone per repo is reused across runs (fast); each PR is checked out
by fetching its head branch and hard-resetting to the exact head commit so the
agent always starts from a clean, known state.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


class WorkspaceError(RuntimeError):
    pass


def _git(args: list[str], cwd: str | Path | None = None) -> str:
    proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise WorkspaceError(
            f"git {' '.join(args)} failed ({proc.returncode}): {(proc.stderr or '').strip()}"
        )
    return proc.stdout


def repo_dir(workspace_root: Path, repo: str) -> Path:
    return workspace_root.expanduser() / repo.replace("/", "__")


def ensure_clone(workspace_root: Path, repo: str) -> Path:
    """Clone `owner/name` if absent, otherwise reuse. Returns the clone path."""
    target = repo_dir(workspace_root, repo)
    if (target / ".git").is_dir():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    # Use the gh-authenticated https remote so pushes reuse GH_TOKEN.
    url = f"https://github.com/{repo}.git"
    _git(["clone", "--quiet", url, str(target)])
    return target


def checkout_pr(workdir: Path, branch: str, head_oid: str) -> None:
    """Fetch the PR head branch and hard-reset the working tree to head_oid."""
    _git(["fetch", "--quiet", "origin", branch], cwd=workdir)
    _git(["checkout", "--quiet", "-B", branch, head_oid], cwd=workdir)
    _git(["reset", "--hard", head_oid], cwd=workdir)
    _git(["clean", "-fdx"], cwd=workdir)


def has_new_commit(workdir: Path, base_oid: str) -> bool:
    """True if HEAD has moved past base_oid (i.e. the agent committed something)."""
    head = _git(["rev-parse", "HEAD"], cwd=workdir).strip()
    return head != base_oid
