"""pr-fixer entrypoint: load config, take the lock, drive the run."""

from __future__ import annotations

import argparse
import asyncio
import sys

from .config import ConfigError, load_config
from .runner import log_event, run
from .state import LockError, lockfile


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pr-fixer", description=__doc__)
    parser.add_argument("--config", help="path to config.yaml (or set PR_FIXER_CONFIG)")
    parser.add_argument("--dry-run", action="store_true",
                        help="override config: diagnose + commit locally, never push")
    args = parser.parse_args(argv)

    try:
        cfg = load_config(args.config)
    except ConfigError as e:
        print(f"config error: {e}", file=sys.stderr)
        return 2

    if args.dry_run:
        cfg.defaults.dry_run = True

    lock_path = cfg.paths.expanded_state_dir() / "pr-fixer.lock"
    try:
        with lockfile(lock_path):
            results = asyncio.run(run(cfg))
    except LockError as e:
        log_event(event="locked", detail=str(e))
        return 0  # another run is active; not an error

    fixed = sum(1 for r in results if r.outcome == "fixed")
    log_event(event="run_complete", processed=len(results), fixed=fixed)
    # Non-zero only on hard errors so cron surfaces genuine breakage.
    return 1 if any(r.outcome == "error" for r in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
