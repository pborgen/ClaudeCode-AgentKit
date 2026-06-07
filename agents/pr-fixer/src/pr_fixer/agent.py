"""Claude Agent SDK invocation: diagnose + fix one PR in its working tree.

The harness owns pushing and the retry loop; this module only runs Claude to
produce (at most) one local commit. Verified against claude-agent-sdk 0.2.93.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from claude_agent_sdk import ClaudeAgentOptions, ResultMessage, query

_PROMPTS = Path(__file__).resolve().parents[2] / "prompts"

# Tools the fixing agent is allowed to use. No network/MCP tools — Bash covers
# running tests and git; push is deliberately excluded by the system prompt.
ALLOWED_TOOLS = ["Read", "Edit", "Write", "Bash", "Glob", "Grep"]


def _read_prompt(name: str) -> str:
    return (_PROMPTS / name).read_text()


def build_task_prompt(
    *,
    repo: str,
    pr_number: int,
    title: str,
    branch: str,
    head_oid: str,
    attempt: int,
    max_attempts: int,
    failing_checks: list[str],
    logs: str,
) -> str:
    tmpl = _read_prompt("task.md.tmpl")
    return tmpl.format(
        repo=repo,
        pr_number=pr_number,
        title=title,
        branch=branch,
        head_oid=head_oid,
        attempt=attempt,
        max_attempts=max_attempts,
        failing_checks=", ".join(failing_checks) or "(unknown)",
        logs=logs,
    )


@dataclass
class AgentOutcome:
    is_error: bool
    subtype: str
    num_turns: int
    total_cost_usd: float | None
    result: str | None
    errors: list[str] | None


def _build_options(workdir: Path, defaults) -> ClaudeAgentOptions:
    env = {}
    # Forward the GitHub token so the agent's Bash (e.g. `gh`, git) stays authed,
    # but never forward the Anthropic key into tool subprocesses.
    if os.environ.get("GH_TOKEN"):
        env["GH_TOKEN"] = os.environ["GH_TOKEN"]

    return ClaudeAgentOptions(
        system_prompt=_read_prompt("system.md"),
        allowed_tools=ALLOWED_TOOLS,
        permission_mode="bypassPermissions",  # unattended; no interactive prompts
        cwd=str(workdir),
        env=env,
        model=defaults.model,
        max_turns=defaults.max_turns,
        max_budget_usd=defaults.max_budget_usd,
    )


async def run_fix(workdir: Path, task_prompt: str, defaults) -> AgentOutcome:
    """Run one fixing pass. Returns the final ResultMessage flattened to AgentOutcome."""
    options = _build_options(workdir, defaults)
    final: ResultMessage | None = None
    async for message in query(prompt=task_prompt, options=options):
        if isinstance(message, ResultMessage):
            final = message

    if final is None:
        return AgentOutcome(
            is_error=True, subtype="no_result", num_turns=0,
            total_cost_usd=None, result=None, errors=["agent produced no result"],
        )
    return AgentOutcome(
        is_error=final.is_error,
        subtype=final.subtype,
        num_turns=final.num_turns,
        total_cost_usd=final.total_cost_usd,
        result=final.result,
        errors=final.errors,
    )
