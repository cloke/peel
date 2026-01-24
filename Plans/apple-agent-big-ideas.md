---
title: Apple-Only Agent Big-Ideas
status: vision
created: 2026-01-16
updated: 2026-01-18
tags: [vision, apple-platform, mlx, metal, ane, isolation]
audience: [developers, stakeholders]
related_docs:
  - Plans/VM_ISOLATION_PLAN.md
  - Plans/ROADMAP.md
---

# Apple-Only Agent Big-Ideas (Throughput + Isolation)

_Last updated: 2026-01-16_

## Index

- [Tag Legend](#tag-legend)
- [North Star](#north-star)
- [Phased Roadmap](#phased-roadmap)
- [Hypervisor & VM Isolation](#hypervisor--vm-isolation)
- [Metal + GPU Throughput](#metal--gpu-throughput)
- [Apple Neural Engine + Core ML](#apple-neural-engine--core-ml)
- [MLX Stack](#mlx-stack)
- [Sandboxing, XPC, and Privilege Separation](#sandboxing-xpc-and-privilege-separation)
- [Local Data Planes](#local-data-planes)
- [Agent Orchestration Patterns](#agent-orchestration-patterns)
- [Vision & Multimodal](#vision--multimodal)
- [Voice & Feedback Loops](#voice--feedback-loops)
- [PII Scrubbing & Data Sanitization](#pii-scrubbing--data-sanitization)
- [Distributed Actors](#distributed-actors)
- [Observability + Safety](#observability--safety)
- [Next Bets (Top Picks)](#next-bets-top-picks)

## Tag Legend

- **throughput**: maximize tokens/sec, batch size, parallelism
- **isolation**: hard boundaries and blast‑radius control
- **orchestration**: agent scheduling, dependency routing
- **safety**: policy enforcement, secrets, guardrails
- **tools**: macOS / Apple‑only tech leverage
- **wwdc**: features that showcase Apple platform capabilities

## North Star

Push Apple hardware to its limits with local agents while keeping strict safety boundaries. Emphasize single‑machine scale‑out using Apple's hypervisor, Metal, ANE, and MLX to achieve both high throughput and strong isolation.

**Goal:** Build features that could be highlighted at WWDC—showcasing what's possible when you fully embrace the Apple platform.

---

## Phased Roadmap

### Phase 2: Local AI Foundation
Build the infrastructure for on-device intelligence:
- [ ] XPC tool brokers for safe agent actions
- [ ] Basic MLX integration (single model, simple inference)
- [ ] PII scrubber for database sanitization (huge productivity win)
- [ ] Budget-aware scheduler (CPU/GPU/ANE allocation)

### Phase 3: Multimodal & Feedback Loops
Add vision, voice, and tight feedback loops:
- [ ] Screen capture → Vision analysis pipeline
- [ ] Voice commands via on-device Whisper
- [ ] Agent feedback loops (watch results, adapt)
- [ ] Distributed Actors for multi-machine coordination

### Phase 4: Full Isolation & Scale
Maximum throughput with maximum safety:
- [ ] Per-task micro-VMs via Hypervisor.framework
- [ ] GPU shared cache service
- [ ] ANE micro-services fleet
- [ ] Speculative agent trees

---

## Hypervisor & VM Isolation

1. **Per‑task micro‑VMs** (**isolation**, **tools**) — Spawn minimal macOS VMs per agent run; destroy after completion for zero state bleed.
2. **Shard‑by‑capability VMs** (**isolation**, **orchestration**) — Separate “read‑only analysis” VM vs “write” VM vs “networked” VM.
3. **Hypervisor‑native rate limits** (**safety**) — Enforce CPU/GPU quotas at VM boundaries to prevent runaway agents.
4. **VM‑level secret vault** (**safety**) — Secrets only injected into a short‑lived VM at runtime.
5. **Filesystem snapshot‑rewind** (**isolation**) — Reset VM disk to a known snapshot after each job.
6. **Hardware partitioning policy** (**throughput**, **isolation**) — Dedicated VM pools mapped to GPU/CPU/ANE priority tiers.
7. **Compile‑farm VMs** (**throughput**) — Use VMs as isolated build workers for agent‑generated code.
8. **Audit VM** (**safety**) — Post‑run VM that replays logs and actions offline for verification.
9. **Sandboxed tool runners** (**tools**) — Gate shell commands through a dedicated VM with restricted system APIs.
10. **Agent A/B lanes** (**orchestration**) — Run risky changes in VM A while VM B stays clean for comparison.

## Metal + GPU Throughput

1. **Metal‑first inference queue** (**throughput**, **tools**) — Pin all GPU inference to a centralized Metal queue to improve batch utilization.
2. **GPU shared cache service** (**throughput**) — Central KV cache service to reduce recompute across agents.
3. **GPU batcher** (**orchestration**) — Aggregate small prompts into larger micro‑batches per frame.
4. **Metal priority lanes** (**throughput**) — Give interactive agents preemptive GPU slots.
5. **GPU safety throttle** (**safety**) — Auto‑degrade models when GPU thermals/pressure spike.
6. **GPU memory guardrails** (**isolation**) — Per‑agent VRAM budget with eviction rules.
7. **Streaming decode** (**throughput**) — Stream tokens to reduce idle time for next agent action.
8. **Multi‑model GPU scheduling** (**orchestration**) — Token‑based scheduler across different model sizes.

## Apple Neural Engine + Core ML

1. **ANE‑only translation fleet** (**throughput**, **tools**) — Pin translation and summarization to ANE via Core ML.
2. **ANE micro‑services** (**orchestration**) — Separate ANE‑powered “fast path” services for common agent tasks.
3. **Core ML model store** (**tools**) — Curated store of optimized models with quantization variants.
4. **ANE fallback ladder** (**safety**) — Fallback to GPU when ANE queue latency exceeds threshold.
5. **ANE fast‑fail guard** (**isolation**) — Abort ANE jobs that exceed time/memory limits.
6. **On‑device PII scrubber** (**safety**) — ANE model that redacts sensitive content before actions.

## MLX Stack

1. **MLX multi‑agent pipeline** (**throughput**, **orchestration**) — Use MLX for fast local training/finetuning loops.
2. **MLX hot‑swap weights** (**throughput**) — Live swap LoRA adapters per agent context.
3. **MLX quantization farm** (**tools**) — Local pipeline to generate multiple quantized variants for latency tradeoffs.
4. **MLX rehearsal cache** (**throughput**) — Cache recent token windows for repeated tasks.
5. **MLX eval harness** (**tools**) — Fast local benchmarking harness for model throughput regression.
6. **MLX instruction router** (**orchestration**) — Route tasks to model sizes by complexity score.

## Sandboxing, XPC, and Privilege Separation

1. **XPC “tool” brokers** (**isolation**, **tools**) — Every external action runs through an XPC broker with policy checks.
2. **Sandbox profile per agent** (**isolation**) — macOS sandbox profiles tailored to agent role.
3. **Read‑only filesystem mounts** (**safety**) — Immutable views for analysis‑only agents.
4. **Network‑less execution zone** (**safety**) — Disable outbound network for “confined” agents.
5. **Token‑scoped automation** (**safety**) — Short‑lived tokens for system automation tasks.
6. **Two‑man rule** (**safety**) — Require a second agent to approve sensitive actions.

## Local Data Planes

1. **Local RAG appliance** (**throughput**) — Always‑on vector DB with memory tiering.
2. **On‑device log lake** (**tools**) — All agent actions and outputs stored locally with rotation.
3. **Tiered memory** (**orchestration**) — Hot memory per agent, warm shared memory, cold archive.
4. **Context deduper** (**throughput**) — Deduplicate identical context across agents.
5. **Unified embedding cache** (**throughput**) — Cache embeddings across tasks and models.

## Agent Orchestration Patterns

1. **Speculative agent tree** (**throughput**) — Spawn parallel solution branches and prune quickly.
2. **Budget‑aware scheduler** (**orchestration**) — Allocate CPU/GPU/ANE based on SLA per task.
3. **Role‑based agent pools** (**isolation**) — “writer”, “reviewer”, “executor” in separate lanes.
4. **Deterministic replay** (**safety**) — Record and replay runs for auditability.
5. **Latency‑aware routing** (**throughput**) — Route tasks to fast models unless quality threshold fails.
6. **Confidence‑gated escalation** (**safety**) — Larger model only if smaller model low confidence.
7. **Multi‑agent quorum** (**safety**) — Require consensus for destructive actions.

## Vision & Multimodal

1. **Screen capture pipeline** (**tools**, **wwdc**) — Use ScreenCaptureKit to feed agent vision models with live app state.
2. **Vision-guided agent** (**orchestration**) — Agent that watches its own effects: run command → screenshot → analyze → adjust.
3. **UI element detection** (**tools**) — Core ML model trained on macOS/iOS UI patterns for accessibility-free automation.
4. **Document understanding** (**throughput**) — Local OCR + layout analysis for PDF/image processing.
5. **Multi-window context** (**orchestration**) — Agent awareness of multiple app windows and their relationships.
6. **Visual diff detection** (**safety**) — Compare before/after screenshots to verify agent actions had intended effect.

## Voice & Feedback Loops

1. **On-device Whisper** (**tools**, **wwdc**) — Local speech-to-text using MLX Whisper, no cloud round-trip.
2. **Voice command router** (**orchestration**) — Natural language → agent task mapping with intent classification.
3. **Audio feedback channel** (**tools**) — Agents can speak status updates via AVSpeechSynthesizer.
4. **Continuous listening mode** (**throughput**) — Background voice activation with wake word detection.
5. **Feedback loop orchestrator** (**orchestration**, **wwdc**) — Closed loop: voice command → agent action → visual confirmation → voice report.
6. **Dictation-to-code** (**tools**) — Voice-driven coding with real-time syntax awareness.
7. **Voice notifications + quick replies** (**tools**, **orchestration**) — Task completion announcements with simple spoken commands (see [#109](https://github.com/cloke/peel/issues/109)).

## PII Scrubbing & Data Sanitization

1. **Postgres dump scrubber** (**tools**, **safety**) — Shell pipeline: `pg_dump` → PII detection → synthetic replacement → safe seed file.
2. **Pattern-based detection** (**safety**) — Regex + heuristics for emails, phones, SSNs, credit cards (fast, low false positives).
3. **NER model layer** (**safety**) — Named Entity Recognition for names, addresses, companies (catches what regex misses).
4. **Consistent fake data** (**tools**) — Same input always maps to same fake output (preserves referential integrity).
5. **Column-level rules** (**safety**) — Declarative config: "users.email → fake email", "users.id → preserve".
6. **Streaming mode** (**throughput**) — Process multi-GB dumps without loading into memory.
7. **Audit report** (**safety**) — Generate summary of what was scrubbed, with sample redactions for verification.
8. **Format preservation** (**tools**) — Maintain data types, lengths, and formats (important for schema constraints).

## Distributed Actors

1. **Cross-machine actor mesh** (**orchestration**, **wwdc**) — Swift Distributed Actors across multiple Macs for horizontal scale.
2. **Task migration** (**throughput**) — Move long-running agent tasks to less-loaded machines.
3. **Capability advertisement** (**orchestration**) — Each machine publishes its resources (GPU cores, ANE, memory).
4. **Consensus protocols** (**safety**) — Distributed agreement for multi-machine destructive actions.
5. **Shared context sync** (**throughput**) — Efficient context/embedding sharing across machines.
6. **Failure recovery** (**isolation**) — Automatic task reassignment when a node goes offline.
7. **Local-first with sync** (**tools**) — Work offline, sync agent results when reconnected.

## Observability + Safety

1. **Per‑agent power telemetry** (**tools**) — Log CPU/GPU/ANE watt usage for tuning.
2. **Thermal budget governor** (**safety**) — Auto‑throttle when thermal headroom drops.
3. **Action audit trail** (**safety**) — Every command/action stored with diffs and checksums.
4. **Policy‑as‑code** (**safety**) — Declarative rules for what agents may access.
5. **Anomaly detector** (**tools**) — Detect runaway loops or abnormal resource spikes.
6. **Chaos‑mode testing** (**safety**) — Simulate failures to test isolation boundaries.

---

## Next Bets (Top Picks)

1. **Per‑task micro‑VMs** — strongest isolation; enables aggressive agent experimentation. ([#106](https://github.com/cloke/peel/issues/106))
2. **GPU shared cache service** — high throughput gains across multi‑agent runs. ([#107](https://github.com/cloke/peel/issues/107))
3. **ANE micro‑services** — offload common tasks and free GPU for heavier models. ([#108](https://github.com/cloke/peel/issues/108))
4. **XPC tool brokers** — clean boundary between agents and system actions. ([#23](https://github.com/cloke/peel/issues/23))
5. **Budget‑aware scheduler** — maximizes parallel throughput under strict hardware limits. ([#41](https://github.com/cloke/peel/issues/41))

