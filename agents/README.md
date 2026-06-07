# Agents

Self-contained agents you can run and **deploy as cron jobs**. Each agent lives in
its own subdirectory, brings its own dependencies and config, and ships a
`deploy/` folder with an installer, a cron-safe `run.sh` wrapper, and a crontab
example. Agents are built on the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview).

| Agent | What it does |
|-------|--------------|
| [`pr-fixer`](pr-fixer) | Watches PRs for failing GitHub Actions, then diagnoses, fixes, tests, and pushes — retrying until CI is green (or capped). |

## Conventions

Each agent directory should provide:

- A **`README.md`** — what it does, setup, safety rails, cost.
- An **entrypoint** runnable headlessly (no interactive prompts) for cron.
- A **`config`** mechanism (file/env) with an example committed and the real one gitignored.
- A **`deploy/`** folder: `install.sh` (venv + deps), `run.sh` (cron wrapper that
  loads secrets + self-locks), and `crontab.example`.
- **Safety rails** for anything that writes to the outside world: allowlists,
  caps/limits, a dry-run mode, and a lockfile to prevent overlapping runs.
- **Structured logging** to stdout so cron logs are greppable.

Secrets live in a gitignored `.env` and are loaded by `run.sh`; never commit keys.
