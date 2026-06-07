from pr_fixer.config import parse_config
from pr_fixer.github import (
    classify_rollup,
    failed_run_ids,
    failing_check_names,
    pr_eligibility,
)


def _checkrun(name, status="COMPLETED", conclusion=None, url=None):
    return {"__typename": "CheckRun", "name": name, "status": status,
            "conclusion": conclusion, "detailsUrl": url}


def test_classify_failing():
    rollup = [_checkrun("build", conclusion="SUCCESS"),
              _checkrun("test", conclusion="FAILURE")]
    assert classify_rollup(rollup) == "failing"


def test_classify_pending():
    rollup = [_checkrun("build", status="IN_PROGRESS", conclusion=None)]
    assert classify_rollup(rollup) == "pending"


def test_classify_passing():
    rollup = [_checkrun("build", conclusion="SUCCESS")]
    assert classify_rollup(rollup) == "passing"


def test_classify_none():
    assert classify_rollup(None) == "none"
    assert classify_rollup([]) == "none"


def test_legacy_status_context_state():
    rollup = [{"__typename": "StatusContext", "context": "ci/legacy", "state": "FAILURE",
               "targetUrl": "https://x/actions/runs/42"}]
    assert classify_rollup(rollup) == "failing"
    assert failing_check_names(rollup) == ["ci/legacy"]
    assert failed_run_ids(rollup) == ["42"]


def test_failed_run_ids_dedup():
    rollup = [
        _checkrun("a", conclusion="FAILURE", url="https://github.com/o/r/actions/runs/100/job/1"),
        _checkrun("b", conclusion="FAILURE", url="https://github.com/o/r/actions/runs/100/job/2"),
        _checkrun("c", conclusion="SUCCESS", url="https://github.com/o/r/actions/runs/999/job/3"),
    ]
    assert failed_run_ids(rollup) == ["100"]


# ---- eligibility ----

DEFAULTS = parse_config({"repos": ["acme/app"]}).defaults


def _pr(**over):
    base = {
        "number": 1, "title": "x", "isDraft": False,
        "headRefName": "feature", "headRefOid": "abc",
        "headRepositoryOwner": {"login": "acme"},
        "author": {"login": "dev"}, "labels": [],
        "statusCheckRollup": [_checkrun("test", conclusion="FAILURE")],
    }
    base.update(over)
    return base


def test_eligible_failing_pr():
    assert pr_eligibility(_pr(), "acme/app", DEFAULTS).eligible


def test_not_eligible_when_passing():
    pr = _pr(statusCheckRollup=[_checkrun("test", conclusion="SUCCESS")])
    assert not pr_eligibility(pr, "acme/app", DEFAULTS).eligible


def test_skip_draft():
    assert not pr_eligibility(_pr(isDraft=True), "acme/app", DEFAULTS).eligible


def test_skip_fork():
    pr = _pr(headRepositoryOwner={"login": "someone-else"})
    assert not pr_eligibility(pr, "acme/app", DEFAULTS).eligible


def test_skip_default_branch_head():
    assert not pr_eligibility(_pr(headRefName="main"), "acme/app", DEFAULTS).eligible


def test_author_allowlist():
    d = parse_config({"repos": ["acme/app"], "defaults": {"author_allowlist": ["alice"]}}).defaults
    assert not pr_eligibility(_pr(author={"login": "bob"}), "acme/app", d).eligible
    assert pr_eligibility(_pr(author={"login": "alice"}), "acme/app", d).eligible
