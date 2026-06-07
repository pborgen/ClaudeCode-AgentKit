# ClaudeCode-AgentKit

A grab-bag of tools and infrastructure for developing with AI — built around
running [Claude Code](https://claude.com/claude-code) from anywhere, including
your phone.

## Setup wizard

New here? Run the interactive wizard — it walks you through the pieces you can
turn on, one at a time:

```bash
scripts/agentkit.sh
```

It can grant Claude full permissions (`.claude/settings.json`), inspect every
Claude Code settings scope and how they resolve, configure and `terraform apply`
the EC2 dev box, start/stop/SSH into it, set up an S3 backend for Terraform
state, and check that your prerequisites are installed. Jump straight to a
section with `scripts/agentkit.sh deploy`, `box`, `permissions`, `settings`,
`state`, or `doctor`.

### Inspect your Claude Code settings

```bash
scripts/agentkit.sh settings          # scopes + resolved settings, with source
scripts/agentkit.sh settings full     # the above, then every scope file dumped
scripts/agentkit.sh settings json     # machine-readable, for agents / jq
```

Shows where each setting lives — user/global (`~/.claude/settings.json`), project
shared (`.claude/settings.json`), project local (`.claude/settings.local.json`),
and enterprise-managed — and which scope wins for each key, so you can see what
overrides what. Permission rule arrays (`allow`/`deny`/`ask`) are flagged as
accumulating across scopes; everything else is overridden by the
highest-precedence scope.

## Contents

| Tool | Description |
|------|-------------|
| [`scripts/agentkit.sh`](scripts/agentkit.sh) | Interactive setup wizard: permissions, settings inspector, deploy/control the dev box, remote state, prereq doctor. |
| [`agents/`](agents) | Self-contained agents you can run and deploy as cron jobs, built on the Claude Agent SDK. Start with [`pr-fixer`](agents/pr-fixer). |
| [`terraform/ec2-dev`](terraform/ec2-dev) | Terraform for an AWS EC2 dev box, reachable over Tailscale, preloaded with Node.js + Claude Code. SSH in from your iPhone and develop on the go. |

## Agents

Deployable agents that run unattended on a schedule. See [`agents/`](agents) for
the collection and its conventions.

| Agent | What it does |
|-------|--------------|
| [`agents/pr-fixer`](agents/pr-fixer) | Watches PRs for failing GitHub Actions, then diagnoses, fixes, tests, and pushes — retrying until CI is green (or capped). Deploys via host crontab. |

## Quick start: develop from your iPhone

1. Stand up the box — run `scripts/agentkit.sh deploy` (or see [`terraform/ec2-dev`](terraform/ec2-dev)).
2. Install **Tailscale** + an SSH client (**Blink Shell** / **Termius**) on your iPhone.
3. `ssh ubuntu@claude-dev`, then run `claude`.

## Stack

- **AWS** (EC2, VPC, IAM/SSM) provisioned with **Terraform**
- **Tailscale** for zero-config, keyless, no-open-ports SSH
- **GitHub** for source
