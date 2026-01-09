# Agent Orchestration - Session Summary (Jan 7-9, 2026)

## Current Status ✅

### Completed Features
| Feature | Commit | Description |
|---------|--------|-------------|
| Basic Agents UI | `b5f7b74` | NavigationSplitView, sidebar, agent detail |
| Copilot CLI Integration | `b5f7b74` | Detection, auth, non-interactive mode |
| Model Selection | `3ead2a9` | All Copilot models with premium costs |
| Working Directory | `3ead2a9` | Folder picker, runs in project context |
| Multi-Agent Chains | `3ead2a9` | Sequential execution, context passing |
| Free Tier Models | `3bcbf40` | GPT 4.1, GPT 5 Mini, Gemini 3 Pro |
| Agent Roles | `7e0e5c4` | Planner (read-only), Implementer, Reviewer |
| UX Improvements | `7e0e5c4` | Visible buttons, no hidden + menu |
| Role System Prompts | `477f065` | Clear instructions for each role |
| Framework Hints | `477f065` | Swift, Ember, React, Python, Rust |
| Apple AI Service | `0ca0742` | On-device Foundation Models integration |
| Brew UI Modernization | `0ca0742` | Segmented picker, .searchable, NavigationStack |
| Live Status Indicator | `c940c35` | Elapsed time + status messages while running |

### What Works Now
- ✅ Create agents with role (Planner/Implementer/Reviewer)
- ✅ Select model with premium cost display
- ✅ Set framework hint (Swift/SwiftUI, Ember, React, etc.)
- ✅ Set working directory for project context
- ✅ Create chains with multiple agents
- ✅ Run chains sequentially with context passing
- ✅ Role-based tool restrictions (--deny-tool for planners/reviewers)
- ✅ System prompts injected for clear role behavior
- ✅ Live status indicator while agent is running

---

## Developer Use Cases 💡

### Translation Workflow (High Value)
As a developer, I frequently need to translate UI strings. This is a perfect hybrid workflow:

**Pain Point:** Translation services cost money, take time, and require sending text off-device.

**Solution with Apple AI:**
1. **Free on-device translation** for initial pass (90%+ of work)
2. **Cloud AI only for context verification** (buttons, tone, technical terms)

**Why This Matters:**
- Translations are a common, repetitive developer task
- Apple's on-device models handle this well
- Saves significant cost vs. sending everything to cloud
- Works offline for basic translations
- Privacy-preserving (source text stays on device)

---

## Apple Intelligence & On-Device AI 🧠

### macOS 26 / iOS 26 New Frameworks

Apple introduced several on-device AI frameworks that could enhance agent orchestration:

#### 1. **Foundation Models Framework** (New in 26)
```swift
import FoundationModels

// On-device language model for quick tasks
let session = LanguageModelSession()
let response = try await session.respond(to: "Summarize this code")
```
**Use Cases:**
- Quick code summarization (no API call needed)
- Local pre-processing before sending to Copilot
- Privacy-sensitive tasks that shouldn't leave device
- Offline capability for basic analysis

#### 2. **Apple Intelligence Integration**
```swift
import AppIntents

// Siri/Apple Intelligence can invoke agents
struct RunAgentIntent: AppIntent {
  static var title: LocalizedStringResource = "Run Agent"
  @Parameter(title: "Prompt") var prompt: String
  
  func perform() async throws -> some IntentResult {
    // Run agent chain
  }
}
```
**Use Cases:**
- "Hey Siri, run my code review chain"
- Shortcuts integration for automated workflows
- Background agent execution

#### 3. **Writing Tools API**
```swift
// Integrate with system-wide Writing Tools
@WritingToolsEnabled
struct CodeEditorView: View { ... }
```
**Use Cases:**
- Proofread/improve generated code
- Rewrite suggestions inline

#### 4. **Neural Engine Direct Access**
```swift
import CoreML

// Custom models on Neural Engine
let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine
```
**Use Cases:**
- Code embedding models for semantic search
- Local classification (Swift vs Ember vs React detection)
- Fast local inference for simple decisions

### Potential Integration Points

| Task | Cloud (Copilot) | On-Device |
|------|-----------------|-----------|
| Complex reasoning | ✅ Opus/GPT-5 | ❌ |
| Code generation | ✅ Sonnet/Codex | ❌ |
| Quick summaries | Optional | ✅ Foundation Models |
| Framework detection | Optional | ✅ Local classifier |
| Code search/embedding | Optional | ✅ CoreML |
| Syntax validation | ❌ | ✅ SourceKit |
| Privacy-sensitive | ❌ | ✅ On-device |

### Implementation Ideas

1. **Hybrid Agent Type**
   ```swift
   enum AgentType {
     case copilot      // Cloud - full capability
     case appleAI      // On-device - fast, private
     case hybrid       // Use on-device for pre-processing, cloud for heavy lifting
   }
   ```

2. **Smart Routing**
   - Detect if task is simple → use on-device
   - Detect if task needs code changes → use Copilot
   - Detect if task is privacy-sensitive → force on-device

3. **Local Pre-Processing**
   - Use Foundation Models to summarize context before sending to Copilot
   - Reduce token usage by pre-filtering relevant code
   - Detect framework locally before adding hints

4. **Hybrid Translation Workflow** 🌐
   A perfect use case for on-device + cloud hybrid:
   
   ```
   ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
   │  Source Text    │────▶│  Apple AI       │────▶│  Cloud AI       │
   │  (English)      │     │  (On-Device)    │     │  (Context Check)│
   └─────────────────┘     └─────────────────┘     └─────────────────┘
                           │                       │
                           │ Fast, Free,           │ Verify translation
                           │ Privacy-safe          │ fits app context
                           │ Translation           │ (UI strings, tone)
                           ▼                       ▼
                           "Guardar cambios"       ✅ "Guardar cambios"
                                                   (correct for button)
   ```
   
   **Step 1: On-Device Translation (Apple Neural Engine)**
   - Use `Translation` framework or Foundation Models
   - Fast, free, works offline
   - Good for bulk translations
   
   **Step 2: Cloud Context Verification (Copilot/GPT)**  
   - Only send translations that need context review
   - Verify UI strings match button/label conventions
   - Check technical terms are translated correctly
   - Ensure tone matches app style
   
   **Benefits:**
   - 90%+ translations done free on-device
   - Only pay for context-sensitive review
   - Privacy: source text never leaves device for initial pass
   - Offline capability for basic translations
   
   **Example Prompts:**
   ```swift
   // On-device (free)
   let translation = try await appleAI.translate("Save changes", to: .spanish)
   // Result: "Guardar cambios"
   
   // Cloud verification (1 premium request for batch)
   let prompt = """
   Review these UI translations for a macOS developer app.
   Verify they're appropriate for buttons/labels:
   - "Save changes" → "Guardar cambios"
   - "Delete repository" → "Eliminar repositorio"
   """
   ```

---

## Next Steps (Priority Order)

### Completed ✅
- [x] Research Foundation Models API availability
- [x] Test if FoundationModels framework is available in macOS 26
- [x] Live status/progress during agent execution

### Short Term (Next Up)
- [ ] **Chain Templates** - Save/load common workflows (Planner→Implementer→Reviewer)
- [ ] **Session Cost Tracking** - Show total premium requests used
- [ ] **Streaming Output** - Show response as it generates (not just status messages)
- [ ] Add `AgentType.appleAI` for on-device tasks
- [ ] Implement framework auto-detection using local analysis

### Medium Term  
- [ ] **Translation Workflow** - On-device translation + cloud context verification
- [ ] **Review Loop** - Back-and-forth between agents until approved
- [ ] Add AppIntents for Siri/Shortcuts integration
- [ ] Real tool invocation status (parse copilot stderr in real-time)

### Long Term
- [ ] Git worktree integration for isolated workspaces
- [ ] Parallel agent execution
- [ ] Custom model fine-tuning for specific codebases

---

## Session Commits
```
6d33175 Add hybrid translation workflow idea to plan
c940c35 Add live status indicator while agent is running
0ca0742 Add AppleAIService for on-device Foundation Models
477f065 Add role system prompts and framework hints
7e0e5c4 Add Agent Roles and improve UX  
3bcbf40 Add free tier models and update session notes
3ead2a9 Add model selection, working directory, and multi-agent chains
19e0884 Update session notes with next steps
b5f7b74 Add Agent Orchestration with Copilot CLI integration
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Kitchen Sync App                      │
├─────────────────────────────────────────────────────────┤
│  Agents_RootView                                         │
│  ├── Sidebar (Agents, Chains, CLI Status)               │
│  ├── AgentDetailView (Model, Role, Framework, Project)  │
│  └── ChainDetailView (Multi-agent orchestration)        │
├─────────────────────────────────────────────────────────┤
│  AgentManager                                            │
│  ├── agents: [Agent]                                    │
│  ├── chains: [AgentChain]                               │
│  └── createAgent/createChain                            │
├─────────────────────────────────────────────────────────┤
│  CLIService                                              │
│  ├── runCopilotSession(prompt, model, role, workDir)    │
│  ├── copilotStatus / claudeStatus                       │
│  └── getGitHubToken()                                   │
├─────────────────────────────────────────────────────────┤
│  Agent Model                                             │
│  ├── role: AgentRole (planner/implementer/reviewer)     │
│  ├── model: CopilotModel                                │
│  ├── frameworkHint: FrameworkHint                       │
│  ├── buildPrompt(userPrompt, context)                   │
│  └── workingDirectory                                   │
└─────────────────────────────────────────────────────────┘
```