"""GitHub access via the `gh` CLI.

Side-effecting calls (list, push, poll, label, comment) shell out to `gh`/`git`.
The decision logic (rollup classification + PR eligibility) is kept as pure
functions so it can be unit-tested against JSON fixtures with no network.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass

# gh pr list --json fields we request.
PR_JSON_FIELDS = (
    "number,title,isDraft,headRefName,headRefOid,"
    "headRepositoryOwner,author,labels,statusCheckRollup"
)

# Conclusions/states that mean a check actually failed.
_FAILED = {"FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED"}
# States (legacy StatusContext) that mean a check has not finished yet.
_PENDING_STATE = {"PENDING", "EXPECTED", "WAITING"}
# CheckRun.status values that mean it has finished.
_COMPLETED = {"COMPLETED"}

_RUN_ID_RE = re.compile(r"/actions/runs/(\d+)")


class GhError(RuntimeError):
    """A `gh`/`git` invocation failed."""


# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def _check_state(check: dict) -> str:
    """Classify a single rollup entry: failure | pending | success."""
    status = (check.get("status") or "").upper()
    conclusion = (check.get("conclusion") or "").upper()
    state = (check.get("state") or "").upper()  # legacy StatusContext

    if conclusion in _FAILED or state in _FAILED:
        return "failure"
    if state in _PENDING_STATE:
        return "pending"
    # CheckRun: pending until COMPLETED with a conclusion.
    if status and status not in _COMPLETED:
        return "pending"
    if status in _COMPLETED and not conclusion:
        return "pending"  # completed but conclusion not yet reported
    return "success"


def classify_rollup(rollup: list[dict] | None) -> str:
    """Reduce a statusCheckRollup to one of: failing | pending | passing | none."""
    if not rollup:
        return "none"
    states = [_check_state(c) for c in rollup]
    if "failure" in states:
        return "failing"
    if "pending" in states:
        return "pending"
    return "passing"


def failing_check_names(rollup: list[dict] | None) -> list[str]:
    out = []
    for check in rollup or []:
        conclusion = (check.get("conclusion") or "").upper()
        state = (check.get("state") or "").upper()
        if conclusion in _FAILED or state in _FAILED:
            out.append(check.get("name") or check.get("context") or "unknown")
    return out


def failed_run_ids(rollup: list[dict] | None) -> list[str]:
    """Parse Actions run ids out of failing checks' detailsUrl/targetUrl."""
    ids: list[str] = []
    for check in rollup or []:
        conclusion = (check.get("conclusion") or "").upper()
        state = (check.get("state") or "").upper()
        if conclusion not in _FAILED and state not in _FAILED:
            continue
        url = check.get("detailsUrl") or check.get("targetUrl") or ""
        m = _RUN_ID_RE.search(url)
        if m and m.group(1) not in ids:
            ids.append(m.group(1))
    return ids


@dataclass
class Eligibility:
    eligible: bool
    reason: str


def pr_eligibility(pr: dict, repo: str, defaults) -> Eligibility:
    """Decide whether a PR should be acted on. `defaults` is a config.Defaults."""
    owner = repo.split("/")[0]

    if classify_rollup(pr.get("statusCheckRollup")) != "failing":
        return Eligibility(False, "checks not failing")

    if defaults.skip_drafts and pr.get("isDraft"):
        return Eligibility(False, "draft PR")

    head_owner = (pr.get("headRepositoryOwner") or {}).get("login")
    if defaults.skip_forks and head_owner and head_owner != owner:
        return Eligibility(False, f"fork PR (head owner {head_owner})")

    if pr.get("headRefName") in {"main", "master"}:
        return Eligibility(False, "head branch is a default branch")

    if defaults.author_allowlist:
        login = (pr.get("author") or {}).get("login")
        if login not in defaults.author_allowlist:
            return Eligibility(False, f"author {login} not in allowlist")

    return Eligibility(True, "failing checks, eligible")


# --------------------------------------------------------------------------- #
# Side-effecting gh/git wrappers
# --------------------------------------------------------------------------- #


def _run(args: list[str], *, cwd: str | None = None, capture: bool = True) -> str:
    proc = subprocess.run(
        args, cwd=cwd, capture_output=capture, text=True,
    )
    if proc.returncode != 0:
        raise GhError(
            f"command failed ({proc.returncode}): {' '.join(args)}\n"
            f"{(proc.stderr or '').strip()}"
        )
    return proc.stdout if capture else ""


def list_open_prs(repo: str) -> list[dict]:
    out = _run([
        "gh", "pr", "list", "--repo", repo, "--state", "open",
        "--limit", "100", "--json", PR_JSON_FIELDS,
    ])
    return json.loads(out or "[]")


def fetch_failed_logs(repo: str, run_ids: list[str], char_budget: int) -> str:
    """Concatenate `gh run view --log-failed` for each failing run, truncated."""
    chunks: list[str] = []
    for rid in run_ids:
        try:
            log = _run(["gh", "run", "view", rid, "--repo", repo, "--log-failed"])
        except GhError as e:
            log = f"(could not fetch logs for run {rid}: {e})"
        chunks.append(f"===== failed run {rid} =====\n{log}")
    blob = "\n\n".join(chunks)
    if len(blob) > char_budget:
        head = char_budget // 2
        blob = blob[:head] + "\n\n...[truncated]...\n\n" + blob[-head:]
    return blob


def poll_checks(repo: str, pr_number: int) -> dict:
    """Return {'state': failing|pending|passing|none, 'oid': headRefOid}."""
    out = _run([
        "gh", "pr", "view", str(pr_number), "--repo", repo,
        "--json", "headRefOid,statusCheckRollup",
    ])
    data = json.loads(out)
    return {
        "state": classify_rollup(data.get("statusCheckRollup")),
        "oid": data.get("headRefOid"),
    }


def failure_context(repo: str, pr_number: int, char_budget: int) -> dict:
    """Fresh failure snapshot for a PR: failing check names + concatenated logs.

    Returns {'failing_checks': [...], 'logs': str, 'run_ids': [...]}.
    """
    out = _run([
        "gh", "pr", "view", str(pr_number), "--repo", repo,
        "--json", "statusCheckRollup",
    ])
    rollup = json.loads(out).get("statusCheckRollup")
    run_ids = failed_run_ids(rollup)
    return {
        "failing_checks": failing_check_names(rollup),
        "run_ids": run_ids,
        "logs": fetch_failed_logs(repo, run_ids, char_budget) if run_ids else "(no Actions run logs available)",
    }


def add_label(repo: str, pr_number: int, label: str) -> None:
    # --add-label creates the label on the repo if missing in recent gh; tolerate errors.
    try:
        _run(["gh", "pr", "edit", str(pr_number), "--repo", repo, "--add-label", label])
    except GhError:
        pass


def remove_label(repo: str, pr_number: int, label: str) -> None:
    try:
        _run(["gh", "pr", "edit", str(pr_number), "--repo", repo, "--remove-label", label])
    except GhError:
        pass


def comment(repo: str, pr_number: int, body: str) -> None:
    _run(["gh", "pr", "comment", str(pr_number), "--repo", repo, "--body", body])


def push(workdir: str, branch: str) -> None:
    _run(["git", "push", "origin", f"HEAD:{branch}"], cwd=workdir)


def head_sha(workdir: str) -> str:
    return _run(["git", "rev-parse", "HEAD"], cwd=workdir).strip()


def diff_stat(workdir: str) -> str:
    return _run(["git", "diff", "--stat", "HEAD~1..HEAD"], cwd=workdir).strip()
