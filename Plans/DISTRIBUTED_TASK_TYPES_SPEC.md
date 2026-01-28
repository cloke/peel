# Distributed Task Types & Payload Specification

**Status:** Design Draft  
**Created:** January 28, 2026  
**Related Issues:** #142, #143, #144, #145, #149, #150

---

## Overview

This document defines the task type catalog, payload schema versioning, storage strategy, and result formats for distributed Peel execution. It extends the architecture described in [DISTRIBUTED_PEEL_DESIGN.md](./DISTRIBUTED_PEEL_DESIGN.md) with concrete type definitions and serialization standards.

---

## Task Type Catalog

| Type | Description | Input | Output |
|------|-------------|-------|--------|
| **RAGIndex** | Index a repository for semantic search | `repoPath: String`, `forceRebuild: Bool` | `chunkCount: Int`, `indexPath: String`, `duration: TimeInterval` |
| **EmbeddingsBatch** | Generate embeddings for text chunks | `chunks: [String]`, `model: String` | `embeddings: [[Float]]`, `dimensions: Int` |
| **GitOps** | Git operations (clone, fetch, checkout) | `operation: GitOperation`, `repoURL: String`, `ref: String?` | `commit: String`, `workingDir: String` |
| **ChainExecution** | Run an MCP chain template | `template: String`, `prompt: String`, `workingDir: String` | `transcript: String`, `exitCode: Int`, `artifacts: [String]` |

### Extension Points

New task types can be added by:
1. Defining a new entry in the catalog table
2. Creating a `{TypeName}Payload` struct conforming to `TaskPayload`
3. Implementing a `{TypeName}Result` struct conforming to `TaskResult`

---

## Payload Schema Versioning

All task payloads include a version envelope to support backward/forward compatibility:

```swift
struct TaskEnvelope: Codable {
  let version: String           // Semantic version (e.g., "1.0.0")
  let taskType: String           // e.g., "RAGIndex"
  let taskId: String             // UUID for tracking
  let createdAt: Date
  let payload: Data              // JSON-encoded type-specific payload
}
```

### Version Compatibility Rules

- **Major version change** (1.x.x → 2.x.x): Breaking changes, old workers must reject
- **Minor version change** (1.0.x → 1.1.x): New optional fields, old workers can proceed
- **Patch version change** (1.0.0 → 1.0.1): Bug fixes, fully compatible

Workers check the `version` field before deserializing `payload`:

```swift
func canHandle(envelope: TaskEnvelope) -> Bool {
  let supported = Version("1.0.0")...Version("1.99.99")
  guard let taskVersion = Version(envelope.version) else { return false }
  return supported.contains(taskVersion)
}
```

---

## Payload Storage Strategy

### Decision Matrix

| Payload Size | Storage Method | Rationale |
|--------------|----------------|-----------|
| **< 1 MB** | Inline CKAsset | Fast, simple, no external dependencies |
| **1 MB - 100 MB** | CloudKit CKAsset with chunking | Leverages CloudKit's built-in compression and CDN |
| **> 100 MB** | External object store (S3/R2) | Avoid CloudKit size limits, better streaming |

### Implementation Example

```swift
struct TaskRecord {
  let taskId: String
  let payloadSize: Int
  
  // Option 1: Inline (< 1 MB)
  let payloadData: Data?
  
  // Option 2: CKAsset (1-100 MB)
  let payloadAsset: CKAsset?
  
  // Option 3: External (> 100 MB)
  let payloadURL: String?  // e.g., "s3://peel-tasks/abc123.payload"
}
```

### Storage Flow

1. **Brain creates task**:
   - If `payload.count < 1_000_000`: Store inline in `payloadData`
   - If `payload.count < 100_000_000`: Write to temp file, create `CKAsset`
   - Else: Upload to S3/R2, store URL in `payloadURL`

2. **Worker fetches task**:
   - If `payloadData` exists: Deserialize directly
   - If `payloadAsset` exists: Download asset, then deserialize
   - If `payloadURL` exists: Stream from external store

3. **Garbage collection**:
   - Delete CKAssets when task record is deleted (automatic)
   - Delete S3 objects via lifecycle policy (7-day TTL)

---

## Per-Task Result Schema

### Result Envelope

```swift
struct ResultEnvelope: Codable {
  let version: String           // Matches request version
  let taskId: String
  let workerId: String          // Device that executed
  let completedAt: Date
  let status: ResultStatus      // success, failure, timeout
  let error: String?            // Only present if status != success
  let result: Data              // JSON-encoded type-specific result
}

enum ResultStatus: String, Codable {
  case success
  case failure
  case timeout
  case cancelled
}
```

### Type-Specific Result Fields

#### RAGIndexResult

```swift
struct RAGIndexResult: Codable, TaskResult {
  let chunkCount: Int
  let indexPath: String         // Path on worker's filesystem
  let duration: TimeInterval
  let indexSize: Int            // Bytes
  let errorsEncountered: Int
}
```

#### EmbeddingsBatchResult

```swift
struct EmbeddingsBatchResult: Codable, TaskResult {
  let embeddings: [[Float]]     // Could be stored externally if large
  let dimensions: Int
  let model: String
  let processingTime: TimeInterval
}
```

#### GitOpsResult

```swift
struct GitOpsResult: Codable, TaskResult {
  let commit: String            // SHA-1 hash
  let workingDir: String
  let branchName: String?
  let filesChanged: Int
}
```

#### ChainExecutionResult

```swift
struct ChainExecutionResult: Codable, TaskResult {
  let transcript: String        // Console output
  let exitCode: Int
  let artifacts: [String]       // Paths to generated files
  let tokensUsed: Int?
  let duration: TimeInterval
}
```

---

## Related Documents

- [DISTRIBUTED_PEEL_DESIGN.md](./DISTRIBUTED_PEEL_DESIGN.md) - Overall architecture
- [RAG_ARCHITECTURE_V2.md](./RAG_ARCHITECTURE_V2.md) - RAG indexing details

---

## Next Steps

1. Implement `TaskEnvelope` and `ResultEnvelope` in `Shared/Distributed/`
2. Create Swift protocols: `TaskPayload`, `TaskResult`
3. Define storage helpers: `PayloadSerializer`, `PayloadStorage`
4. Add unit tests for versioning and serialization edge cases
