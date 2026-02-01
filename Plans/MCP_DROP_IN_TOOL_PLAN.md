---
title: MCP Drop‑In Tool Plan
status: draft
created: 2026-02-01
updated: 2026-02-01
tags: [mcp, headless, cli, modularity]
audience: [developers]
---

# MCP Drop‑In Tool Plan

## Summary
Create a fully drop‑in MCP tool stack that can be embedded in other apps (or run headless), with a
clear separation between reusable framework code and app‑specific integrations.

## Goals
- Extract MCP server networking + tool registry into a reusable package.
- Replace app‑specific settings access with explicit configuration inputs.
- Provide a headless CLI target that launches MCP without a SwiftUI shell.
- Maintain a clean boundary between generic MCP components and app‑specific tools/UI.

## Non‑Goals
- Provide UI automation tools in headless mode.
- Ship a production‑ready external distribution (GitHub repo split) in this phase.

## Current State
- **MCPCore** is a portable package with types, templates, and DTOs.
- MCP server and tool implementations live in app code, with settings tied to `UserDefaults`.
- UI automation/screenshot tools depend on AppKit/ScreenCaptureKit.

## Target Architecture
- **MCPCore** (existing): types, templates, DTOs, persistence protocols.
- **MCPServerKit** (new package): JSON‑RPC server, request routing, tool registry, permissions, and
  core chain execution.
- **MCPApp** (current app): app‑specific tools, UI automation tools, SwiftData storage, UI.
- **MCPCLI** (new target): headless bootstrap using config file + allowlist of tools.

## Workstreams
1. **Server Extraction**
   - Move JSON‑RPC server and tool registry into MCPServerKit.
   - Define minimal protocol surfaces for tool handlers and execution results.
2. **Configuration Abstraction**
   - Replace `UserDefaults` usage with a config interface usable by app + CLI.
3. **Tool Segmentation & Feature Flags**
   - Explicit tool categories: core vs UI‑only.
   - Gate UI automation/screenshot tools behind feature flags for headless mode.
4. **Headless CLI**
   - CLI bootstrap reads config file (port, allowlist, repo root, templates, data store path).
   - Start server and log to stdout.
5. **Docs + Integration Guide**
   - Provide a minimal embedding guide for host apps and CLI usage.

## Milestones
- M1: MCPServerKit package compiles in isolation with basic tools.
- M2: App builds using MCPServerKit with no functional regression.
- M3: MCPCLI can start server and list tools in headless mode.
- M4: Documentation for embedding + CLI usage published.

## Risks
- Hidden AppKit dependencies in tool handlers.
- Settings or storage coupled to app UI expectations.
- Maintaining compatibility with existing MCP templates and permissions.

## Required Issues
- Extract MCP server + registry into MCPServerKit.
- Introduce MCP server configuration abstraction.
- Segment tools + add headless gating.
- Build MCPCLI target + config loader.
- Document embedding + CLI usage.
