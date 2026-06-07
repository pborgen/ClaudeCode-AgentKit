"""The orchestration loop: find eligible failing PRs and drive fixes to green.

The harness owns every GitHub side effect (checkout, push, CI polling, labels).
Claude only produces local commits (see agent.py).
"""

from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from . import github, workspace
from .agent import build_task_prompt, run_fix
from .config import Config
from .state import AttemptStore, attempt_key


def log_event(**fields) -> None:
    """One structured JSON line per significant event, for the cron log."""
    print(json.dumps(fields, default=str), flush=True)


@dataclass
class PRResult:
    repo: str
    pr: int
    outcome: str  # fixed | gave_up | declined | dry_run | skipped | error
    attempts: int
    detail: str = ""


def _has_label(pr: dict, name: str) -> bool:
    return any((lbl.get("name") == name) for lbl in (pr.get("labels") or []))


async def fix_pr(repo: str, pr: dict, cfg: Config, store: AttemptStore) -> PRResult:
    d = cfg.defaults
    number = pr["number"]
    branch = pr["headRefName"]
    original_oid = pr["headRefOid"]
    key = attempt_key(repo, number, original_oid)

    if store.exhausted(key, d.max_attempts):
        github.add_label(repo, number, cfg.labels.gave_up)
        log_event(event="skip_exhausted", repo=repo, pr=number, sha=original_oid)
        return PRResult(repo, number, "gave_up", store.attempts(key), "attempts exhausted for commit")

    workdir = workspace.ensure_clone(cfg.paths.expanded_workspace_root(), repo)
    github.add_label(repo, number, cfg.labels.in_progress)

    current_oid = original_oid
    attempts_made = store.attempts(key)
    try:
        while store.attempts(key) < d.max_attempts:
            attempt_no = store.record_attempt(key)
            attempts_made = attempt_no
            log_event(event="attempt_start", repo=repo, pr=number, attempt=attempt_no,
                      max_attempts=d.max_attempts, sha=current_oid)

            workspace.checkout_pr(workdir, branch, current_oid)
            ctx = github.failure_context(repo, number, d.log_char_budget)

            prompt = build_task_prompt(
                repo=repo, pr_number=number, title=pr.get("title", ""),
                branch=branch, head_oid=current_oid, attempt=attempt_no,
                max_attempts=d.max_attempts, failing_checks=ctx["failing_checks"],
                logs=ctx["logs"],
            )
            outcome = await run_fix(workdir, prompt, d)
            log_event(event="agent_done", repo=repo, pr=number, attempt=attempt_no,
                      subtype=outcome.subtype, is_error=outcome.is_error,
                      turns=outcome.num_turns, cost_usd=outcome.total_cost_usd)

            if not workspace.has_new_commit(workdir, current_oid):
                # Agent declined to commit (couldn't find a safe fix).
                github.add_label(repo, number, cfg.labels.gave_up)
                github.comment(repo, number, _declined_comment(outcome))
                return PRResult(repo, number, "declined", attempt_no, outcome.subtype)

            if d.dry_run:
                github.comment(repo, number, _dry_run_comment(workdir, outcome))
                log_event(event="dry_run_commit", repo=repo, pr=number, attempt=attempt_no)
                return PRResult(repo, number, "dry_run", attempt_no, "proposed fix, not pushed")

            github.push(str(workdir), branch)
            current_oid = github.head_sha(str(workdir))
            log_event(event="pushed", repo=repo, pr=number, attempt=attempt_no, sha=current_oid)

            ci = _wait_for_ci(repo, number, d.ci_wait_timeout, d.ci_poll_interval)
            log_event(event="ci_result", repo=repo, pr=number, attempt=attempt_no, ci=ci)
            if ci == "passing":
                github.remove_label(repo, number, cfg.labels.in_progress)
                github.comment(repo, number, _success_comment(attempt_no))
                return PRResult(repo, number, "fixed", attempt_no, "checks green")
            # still failing (or timed out) -> next attempt builds on the pushed commit

        # Loop fell through: attempts exhausted without going green.
        github.add_label(repo, number, cfg.labels.gave_up)
        github.comment(repo, number, _gave_up_comment(d.max_attempts))
        return PRResult(repo, number, "gave_up", attempts_made, "exhausted attempts")
    finally:
        github.remove_label(repo, number, cfg.labels.in_progress)


def _wait_for_ci(repo: str, number: int, timeout: int, interval: int) -> str:
    """Poll the rollup until conclusive or timeout. Returns passing|failing|timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = github.poll_checks(repo, number)["state"]
        if state in ("passing", "failing", "none"):
            return "passing" if state == "passing" else "failing"
        time.sleep(interval)
    return "timeout"


def _success_comment(attempt: int) -> str:
    return (f"✅ **pr-fixer**: checks are green after {attempt} "
            f"attempt{'s' if attempt != 1 else ''}.")


def _gave_up_comment(max_attempts: int) -> str:
    return (f"⚠️ **pr-fixer**: gave up after {max_attempts} attempts — checks are "
            f"still failing. A human should take a look.")


def _declined_comment(outcome) -> str:
    body = outcome.result or "(no explanation)"
    return ("🤔 **pr-fixer**: I couldn't find a safe fix, so I made no changes.\n\n"
            f"{body}")


def _dry_run_comment(workdir: Path, outcome) -> str:
    stat = github.diff_stat(str(workdir))
    body = outcome.result or ""
    return ("🧪 **pr-fixer (dry-run)**: proposed fix below — not pushed.\n\n"
            f"```\n{stat}\n```\n\n{body}")


async def run(cfg: Config) -> list[PRResult]:
    """Process every eligible failing PR across all configured repos."""
    store = AttemptStore(cfg.paths.expanded_state_dir() / "attempts.json")
    results: list[PRResult] = []

    for repo in cfg.repos:
        if not cfg.is_repo_allowed(repo):  # defensive; repos come from the allowlist
            continue
        try:
            prs = github.list_open_prs(repo)
        except github.GhError as e:
            log_event(event="list_error", repo=repo, error=str(e))
            continue

        for pr in prs:
            if _has_label(pr, cfg.labels.gave_up):
                log_event(event="skip_gave_up_label", repo=repo, pr=pr["number"])
                continue
            elig = github.pr_eligibility(pr, repo, cfg.defaults)
            if not elig.eligible:
                continue
            log_event(event="eligible", repo=repo, pr=pr["number"], reason=elig.reason)
            try:
                res = await fix_pr(repo, pr, cfg, store)
            except Exception as e:  # one PR's failure must not sink the run
                log_event(event="pr_error", repo=repo, pr=pr["number"], error=str(e))
                res = PRResult(repo, pr["number"], "error", 0, str(e))
            results.append(res)
            log_event(event="pr_result", **asdict(res))

    return results
