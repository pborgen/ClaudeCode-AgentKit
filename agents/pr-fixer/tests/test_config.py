import pytest

from pr_fixer.config import ConfigError, parse_config


def test_parse_minimal():
    cfg = parse_config({"repos": ["owner/name"]})
    assert cfg.repos == ["owner/name"]
    assert cfg.defaults.max_attempts == 3
    assert cfg.defaults.model == "claude-opus-4-8"
    assert cfg.is_repo_allowed("owner/name")
    assert not cfg.is_repo_allowed("someone/else")


def test_overrides():
    cfg = parse_config({
        "repos": ["a/b"],
        "defaults": {"max_attempts": 5, "dry_run": True, "max_budget_usd": 1.5,
                     "author_allowlist": ["alice"]},
        "labels": {"gave_up": "x:done"},
    })
    assert cfg.defaults.max_attempts == 5
    assert cfg.defaults.dry_run is True
    assert cfg.defaults.max_budget_usd == 1.5
    assert cfg.defaults.author_allowlist == ["alice"]
    assert cfg.labels.gave_up == "x:done"


def test_empty_budget_is_none():
    cfg = parse_config({"repos": ["a/b"], "defaults": {"max_budget_usd": None}})
    assert cfg.defaults.max_budget_usd is None


def test_missing_repos_rejected():
    with pytest.raises(ConfigError):
        parse_config({})


def test_bad_repo_form_rejected():
    with pytest.raises(ConfigError):
        parse_config({"repos": ["not-a-slug"]})


def test_zero_attempts_rejected():
    with pytest.raises(ConfigError):
        parse_config({"repos": ["a/b"], "defaults": {"max_attempts": 0}})
