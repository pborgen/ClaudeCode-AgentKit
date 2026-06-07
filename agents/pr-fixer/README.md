# pr-fixer

An autonomous agent that watches your PRs for **failing GitHub Actions**,
diagnoses the failure with Claude (via the **Claude Agent SDK**), fixes the
code, verifies locally, pushes to the PR branch, and **retries until CI is
green** — or gives up after a capped number of attempts. Built to run unattended
from a **host crontab** (the AgentKit EC2 box, or any Linux/Mac).

## How it works

Each run (one cron tick):

1. Takes a lockfile so overlapping ticks don't race.
2. For every repo in your allowlist, lists open PRs and reads their check rollup.
3. Picks the **eligible failing** PRs (see [Safety](#safety-rails)).
4. For each, runs the fix loop up to `max_attempts`:
   checkout the PR at its head commit → pull the failed CI logs → run Claude to
   diagnose + edit + **run tests locally until green** + make one `fix:` commit →
   the harness **pushes** → polls CI → green? done : try again.
5. On success, comments and clears the working label. On exhaustion, labels the
   PR `agentkit:gave-up` and comments for a human.

A clean split of responsibility: **the Python harness owns every GitHub side
effect** (checkout, push, CI polling, labels). **Claude only produces a local
commit** — it is explicitly forbidden from pushing. That keeps the retry loop and
spend deterministic.

## Setup

Prereqs on the host: `python3` (≥3.10), `git`, and the `gh` GitHub CLI.

```bash
cd agents/pr-fixer
./deploy/install.sh            # creates .venv, installs the package, scaffolds config
```

Then:

1. **`config.yaml`** — list the repos to watch and tune the caps
   (see [`config.example.yaml`](config.example.yaml)).
2. **`.env`** — `ANTHROPIC_API_KEY` (required; unattended runs need an API key,
   not a claude.ai login) and `GH_TOKEN` with `repo` scope. Or run `gh auth login`
   once and drop `GH_TOKEN`.
3. **Dry run** (diagnoses + commits locally, **never pushes** — posts the proposed
   diff as a PR comment instead):
   ```bash
   ./deploy/run.sh --dry-run
   ```
4. **Schedule** it (every 15 min):
   ```bash
   crontab -e
   # */15 * * * * /abs/path/agents/pr-fixer/deploy/run.sh >> /abs/path/agents/pr-fixer/pr-fixer.log 2>&1
   ```

## Safety rails

- **Repo allowlist** — only repos in `config.yaml` are ever touched.
- **Never the default branch** — pushes only to the PR's *head* branch; skips a PR
  whose head is `main`/`master`.
- **Skips fork PRs and drafts** by default; optional **author allowlist**.
- **Attempt cap per commit** — once `max_attempts` is spent on a commit, the PR is
  labeled `agentkit:gave-up` and never retried for that commit (prevents infinite
  spend). A human removing the label (typically after pushing new work) re-enables it.
- **`max_turns`** and optional **`max_budget_usd`** bound each agent run.
- **Dry-run mode** — propose without pushing.
- **Lockfile** — no overlapping runs.
- **Won't weaken tests** — the system prompt forbids deleting/skipping tests or
  hardcoding values to force a pass; if no safe fix is found, it commits nothing
  and comments instead.

## Observability

Every run emits structured JSON lines (one per event: `eligible`, `attempt_start`,
`agent_done` with turns + `cost_usd`, `pushed`, `ci_result`, `pr_result`, …) to
stdout — i.e. into `pr-fixer.log` under cron. Grep it to see what happened and what
it cost.

## Layout

```
src/pr_fixer/
  __main__.py   entrypoint: config + lock + run
  config.py     YAML config + validation
  github.py     gh/git wrappers + pure rollup/eligibility logic (unit-tested)
  workspace.py  per-repo clone, fetch + checkout PR head
  agent.py      Claude Agent SDK call (diagnose + fix → one commit)
  runner.py     the per-PR fix loop
  state.py      attempt store + lockfile
prompts/        system + task templates
deploy/         install.sh, run.sh, crontab.example
tests/          pytest (config, eligibility, state)
```

## Tests

```bash
.venv/bin/pip install -e '.[dev]'
.venv/bin/pytest
```
