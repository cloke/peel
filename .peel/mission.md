# Peel Mission Statement

> **Version:** 1.0
> **Last Updated:** 2026-03-13
> **Status:** Active

## Purpose

Peel is a macOS-native agent coordinator that orchestrates development work across a swarm of machines, then provides structured review of that work — by humans or by agents.

## Core Loop

```
Analyze code → Plan work → Execute via agents → Review results → Merge or iterate
```

## What Peel IS

- An MCP server that coordinates AI agents doing real development work in git worktrees
- A code review surface for agent-produced changes (diffs, builds, tests)
- A swarm coordinator that distributes work across multiple Macs
- A RAG-powered code intelligence system that gives agents deep codebase context
- Self-improving: Peel builds Peel — agents can improve the tool that orchestrates them

## What Peel is NOT

- Not a general-purpose IDE or code editor
- Not a cloud service — local-first, your machines, your data
- Not a mobile app — macOS only
- Not a chatbot — it coordinates work, not conversation

## Core Values (Priority Order)

1. **Autonomy with oversight** — agents work independently but humans (or reviewer agents) approve before merge
2. **Local-first** — code, embeddings, and coordination stay on your machines
3. **Self-hosting** — Peel should be able to dispatch chains to improve itself
4. **Transparency** — every agent action is logged, reviewable, and auditable
5. **Composability** — small, focused agents composed into chains beat monolithic agents

## Shippable Criteria

A release-ready Peel means:
- A new user can install, point at a repo, and dispatch agent work within 10 minutes
- Agent results are reviewable, approvable, and mergeable from the UI
- The app builds cleanly with zero warnings and no dead code paths
- Self-hosting works: Peel can dispatch chains to improve itself, rebuild, and continue

## Agent Guidelines

When working on Peel, agents MUST:
- Check this mission before planning work — reject tasks that don't serve the core loop
- Prefer small, reviewable changes over large rewrites
- Always work in git worktrees, never the main checkout
- Run build verification after changes
- Reference existing patterns via RAG before writing new code

When working on ANY project, agents SHOULD:
- Read the project's `.peel/mission.md` if it exists
- Align task planning with the project's stated purpose
- Flag work that seems misaligned with the mission
