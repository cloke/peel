# Local Chat Guide (MLX)

**Created:** February 19, 2026
**Status:** Active

---

## Overview

Peel includes an on-device LLM chat powered by MLX (Apple's machine learning framework for Apple Silicon). Chat with language models locally without any cloud API.

---

## Getting Started

### Opening Local Chat

1. Navigate to **Agents** (sidebar)
2. Click **Local Chat** in the Tools section

### First Use

On first use, Peel will download the appropriate model from HuggingFace. This is a one-time operation:
- Model selection is automatic based on available RAM
- Download progress is shown in the chat view
- Models are cached locally for future use

---

## Model Tiers

Peel auto-selects the best model for your hardware:

| RAM | Default Model | Architecture | Notes |
|-----|--------------|-------------|-------|
| 128GB+ | Qwen3-Coder-Next (80B MoE) | `qwen3_next` | Best quality, 3B active params, 256K context |
| 96GB+ | Qwen3-Coder-30B (MoE) | `qwen3_moe` | Good quality, 3B active params, 128K context |
| 48-96GB | Qwen2.5-Coder-14B | `qwen2` | Balanced quality/speed |
| 24-48GB | Qwen2.5-Coder-7B | `qwen2` | Faster, lighter |

### Manual Tier Selection

Use the model picker at the top of the chat view to override auto-selection:
- **Auto** — Recommended, picks best for your hardware
- Manual tiers let you choose smaller (faster) or larger (smarter) models

---

## Features

### Streaming Responses
Tokens are generated and displayed in real-time. A tokens/sec indicator shows generation performance.

### Conversation History
Messages persist within the current session. Use the **Clear** button to reset.

### Controls

| Control | Action |
|---------|--------|
| **Enter** | Send message |
| **Stop** | Cancel generation mid-stream |
| **Clear** | Reset conversation |
| **Model picker** | Switch model tier |

---

## Code Editing (Related)

For programmatic code editing via MCP, use the `code.edit` tools instead of chat:

```bash
# Edit a file with local MLX model
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"code.edit",
      "arguments":{
        "filePath":"/path/to/file.swift",
        "instruction":"Add error handling to this function"
      }
    }
  }'

# Check status
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"code.edit.status","arguments":{}}}'

# Unload model to free memory
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"code.edit.unload","arguments":{}}}'
```

---

## Performance Tips

1. **Close other memory-intensive apps** — MLX models need contiguous memory
2. **Use Auto tier** — It picks the best model for your available RAM
3. **Unload when done** — Free memory after extended use via `code.edit.unload`
4. **Monitor tokens/sec** — If generation is slow, try a smaller model tier

---

## Troubleshooting

### Model Download Fails
- Check network connectivity
- Verify HuggingFace is accessible
- Try again — downloads auto-resume

### Slow Generation
- Try a smaller model tier
- Close memory-intensive applications
- Check Activity Monitor for memory pressure

### Model Won't Load
- Verify sufficient RAM for the selected tier
- Check disk space (models are several GB)
- Restart the app and try again

---

## Related Docs

- [PRODUCT_MANUAL.md](../PRODUCT_MANUAL.md) — Full feature documentation
- [LOCAL_RAG_GUIDE.md](LOCAL_RAG_GUIDE.md) — RAG search for code context
