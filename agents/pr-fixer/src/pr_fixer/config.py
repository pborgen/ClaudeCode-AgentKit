"""Configuration loading and validation for pr-fixer."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

import yaml


class ConfigError(ValueError):
    """Raised when the config file is missing required values or malformed."""


@dataclass
class Defaults:
    max_attempts: int = 3
    ci_wait_timeout: int = 1200
    ci_poll_interval: int = 30
    model: str = "claude-opus-4-8"
    max_turns: int = 20
    max_budget_usd: float | None = None
    log_char_budget: int = 20000
    skip_drafts: bool = True
    skip_forks: bool = True
    dry_run: bool = False
    author_allowlist: list[str] = field(default_factory=list)


@dataclass
class Labels:
    in_progress: str = "agentkit:fixing"
    gave_up: str = "agentkit:gave-up"


@dataclass
class Paths:
    workspace_root: Path = Path("~/.agentkit/pr-fixer/workspaces")
    state_dir: Path = Path("~/.agentkit/pr-fixer/state")

    def expanded_workspace_root(self) -> Path:
        return Path(self.workspace_root).expanduser()

    def expanded_state_dir(self) -> Path:
        return Path(self.state_dir).expanduser()


@dataclass
class Config:
    repos: list[str]
    defaults: Defaults
    labels: Labels
    paths: Paths

    def is_repo_allowed(self, repo: str) -> bool:
        """Only repos explicitly listed in config are ever touched."""
        return repo in self.repos


def _require_repos(raw: dict) -> list[str]:
    repos = raw.get("repos")
    if not repos or not isinstance(repos, list):
        raise ConfigError("config must define a non-empty `repos` list (owner/name).")
    for r in repos:
        if not isinstance(r, str) or r.count("/") != 1:
            raise ConfigError(f"invalid repo {r!r}; expected 'owner/name'.")
    return repos


def load_config(path: str | os.PathLike | None = None) -> Config:
    """Load and validate config from `path`, $PR_FIXER_CONFIG, or ./config.yaml."""
    resolved = path or os.environ.get("PR_FIXER_CONFIG") or "config.yaml"
    p = Path(resolved).expanduser()
    if not p.is_file():
        raise ConfigError(f"config file not found: {p}")
    raw = yaml.safe_load(p.read_text()) or {}
    if not isinstance(raw, dict):
        raise ConfigError("config root must be a mapping.")

    return parse_config(raw)


def parse_config(raw: dict) -> Config:
    """Parse an already-loaded mapping into a validated Config (kept separate for tests)."""
    repos = _require_repos(raw)

    d = raw.get("defaults") or {}
    if not isinstance(d, dict):
        raise ConfigError("`defaults` must be a mapping.")
    defaults = Defaults(
        max_attempts=int(d.get("max_attempts", 3)),
        ci_wait_timeout=int(d.get("ci_wait_timeout", 1200)),
        ci_poll_interval=int(d.get("ci_poll_interval", 30)),
        model=str(d.get("model", "claude-opus-4-8")),
        max_turns=int(d.get("max_turns", 20)),
        max_budget_usd=(None if d.get("max_budget_usd") in (None, "") else float(d["max_budget_usd"])),
        log_char_budget=int(d.get("log_char_budget", 20000)),
        skip_drafts=bool(d.get("skip_drafts", True)),
        skip_forks=bool(d.get("skip_forks", True)),
        dry_run=bool(d.get("dry_run", False)),
        author_allowlist=list(d.get("author_allowlist") or []),
    )
    if defaults.max_attempts < 1:
        raise ConfigError("defaults.max_attempts must be >= 1.")

    lbl = raw.get("labels") or {}
    labels = Labels(
        in_progress=str(lbl.get("in_progress", "agentkit:fixing")),
        gave_up=str(lbl.get("gave_up", "agentkit:gave-up")),
    )

    pth = raw.get("paths") or {}
    paths = Paths(
        workspace_root=Path(pth.get("workspace_root", "~/.agentkit/pr-fixer/workspaces")),
        state_dir=Path(pth.get("state_dir", "~/.agentkit/pr-fixer/state")),
    )

    return Config(repos=repos, defaults=defaults, labels=labels, paths=paths)
