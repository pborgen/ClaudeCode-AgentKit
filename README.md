# ClaudeCode-AgentKit

A grab-bag of tools and infrastructure for developing with AI — built around
running [Claude Code](https://claude.com/claude-code) from anywhere, including
your phone.

## Contents

| Tool | Description |
|------|-------------|
| [`terraform/ec2-dev`](terraform/ec2-dev) | Terraform for an AWS EC2 dev box, reachable over Tailscale, preloaded with Node.js + Claude Code. SSH in from your iPhone and develop on the go. |

## Quick start: develop from your iPhone

1. Stand up the box — see [`terraform/ec2-dev`](terraform/ec2-dev).
2. Install **Tailscale** + an SSH client (**Blink Shell** / **Termius**) on your iPhone.
3. `ssh ubuntu@claude-dev`, then run `claude`.

## Stack

- **AWS** (EC2, VPC, IAM/SSM) provisioned with **Terraform**
- **Tailscale** for zero-config, keyless, no-open-ports SSH
- **GitHub** for source
