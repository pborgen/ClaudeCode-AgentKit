"""Durable state: per-(PR, head-SHA) attempt counts, plus a cross-run lockfile.

State prevents two failure modes:
  * Infinite spend: a commit that can't be fixed is retried forever.
  * Overlapping cron runs racing on the same PRs.
"""

from __future__ import annotations

import json
import os
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path


def attempt_key(repo: str, pr_number: int, head_sha: str) -> str:
    """Identity of a unit of work. Tied to head_sha so a new commit resets attempts."""
    return f"{repo}#{pr_number}@{head_sha}"


@dataclass
class AttemptStore:
    """JSON-backed map of attempt_key -> number of attempts made."""

    path: Path

    def _load(self) -> dict[str, int]:
        if not self.path.is_file():
            return {}
        try:
            data = json.loads(self.path.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
        return data if isinstance(data, dict) else {}

    def _save(self, data: dict[str, int]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
        tmp.replace(self.path)

    def attempts(self, key: str) -> int:
        return int(self._load().get(key, 0))

    def record_attempt(self, key: str) -> int:
        data = self._load()
        data[key] = int(data.get(key, 0)) + 1
        self._save(data)
        return data[key]

    def exhausted(self, key: str, max_attempts: int) -> bool:
        return self.attempts(key) >= max_attempts


class LockError(RuntimeError):
    """Raised when another run already holds the lock."""


@contextmanager
def lockfile(path: Path):
    """Best-effort exclusive lock via O_CREAT|O_EXCL. Stale-lock aware.

    Yields if acquired; raises LockError if another live process holds it.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    acquired = False
    try:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            if _lock_is_stale(path):
                # Reclaim: remove and retry once.
                try:
                    path.unlink()
                    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                except (FileExistsError, OSError) as e:
                    raise LockError(f"another pr-fixer run holds {path}") from e
            else:
                raise LockError(f"another pr-fixer run holds {path}")
        with os.fdopen(fd, "w") as f:
            f.write(str(os.getpid()))
        acquired = True
        yield
    finally:
        if acquired:
            try:
                path.unlink()
            except OSError:
                pass


def _lock_is_stale(path: Path) -> bool:
    """A lock is stale if its PID is no longer a running process."""
    try:
        pid = int(path.read_text().strip())
    except (ValueError, OSError):
        return True
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)  # signal 0: existence check, no-op if alive
    except ProcessLookupError:
        return True
    except PermissionError:
        return False  # exists but owned by another user — treat as live
    return False
