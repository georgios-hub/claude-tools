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

Usage: `./run-claude.sh --agent my-agent`
