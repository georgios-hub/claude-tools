# agents/

This directory is bind-mounted into the container at `~/.claude/agents`, so any
agent placed here is available in **every** project inside the container while
staying version-controlled in this repository.

Each agent is a `.md` file with YAML front matter:

```markdown
---
name: my-agent
description: When this agent should be used.
tools: Read, Grep, Glob, Bash    # optional -- defaults to all tools
model: sonnet                    # optional: sonnet | opus | haiku | inherit
---

The agent's system prompt.
```

The mount is read-write, so agents that Claude creates itself (via `/agents`)
are written straight into this directory and can be committed.

**The container guidance is duplicated on purpose.** `code-reviewer.md`,
`developer.md` and `senior-dev.md` each carry their own "Containers" section,
tailored to the role. Claude Code loads the agent `.md` files as system prompts
and nothing else in this directory — this README included — so an agent cannot
follow a reference to a shared file it never sees. Change the three copies
together.

Usage: `./run-claude.sh --agent my-agent`
