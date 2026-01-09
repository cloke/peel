# Agent Orchestration - Session Summary (Jan 7-8, 2026)

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

### What Works Now
- ✅ Create agents with role (Planner/Implementer/Reviewer)
- ✅ Select model with premium cost display
- ✅ Set framework hint (Swift/SwiftUI, Ember, React, etc.)
- ✅ Set working directory for project context
- ✅ Create chains with multiple agents
- ✅ Run chains sequentially with context passing
- ✅ Role-based tool restrictions (--deny-tool for planners/reviewers)
- ✅ System prompts injected for clear role behavior

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

---

## Next Steps (Priority Order)

### Immediate (This Session)
- [ ] Research Foundation Models API availability
- [ ] Test if FoundationModels framework is available in macOS 26

### Short Term
- [ ] Add `AgentType.appleAI` for on-device tasks
- [ ] Implement framework auto-detection using local analysis
- [ ] Add AppIntents for Siri/Shortcuts integration

### Medium Term  
- [ ] Chain Templates (save/load workflows)
- [ ] Review Loop (back-and-forth between agents)
- [ ] Live status/progress during agent execution
- [ ] Session cost tracking

### Long Term
- [ ] Git worktree integration for isolated workspaces
- [ ] Parallel agent execution
- [ ] Custom model fine-tuning for specific codebases

---

## Session Commits
```
594cce6 Add AppleAIService for on-device Foundation Models
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