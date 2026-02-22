//
//  RAGToolsHandler+Types.swift
//  Peel
//
//  Supporting types for RAGToolsHandler.
//  Split from RAGToolsHandler.swift as part of #301.
//

import Foundation

// MARK: - Supporting Types (Prefixed to avoid conflicts with existing types)

/// RAG search result structure used by RAGToolsHandler
struct RAGToolSearchResult {
  let filePath: String
  let startLine: Int
  let endLine: Int
  let snippet: String
  let isTest: Bool
  let lineCount: Int
  let constructType: String?
  let constructName: String?
  let language: String?
  let score: Double?
  // Facets (schema v4+)
  let modulePath: String?
  let featureTags: [String]
  // AI analysis (schema v7+)
  let aiSummary: String?
  let aiTags: [String]
  /// Token count for the original code chunk
  let tokenCount: Int?
  
  init(filePath: String, startLine: Int, endLine: Int, snippet: String, isTest: Bool, lineCount: Int, constructType: String? = nil, constructName: String? = nil, language: String? = nil, score: Double? = nil, modulePath: String? = nil, featureTags: [String] = [], aiSummary: String? = nil, aiTags: [String] = [], tokenCount: Int? = nil) {
    self.filePath = filePath
    self.startLine = startLine
    self.endLine = endLine
    self.snippet = snippet
    self.isTest = isTest
    self.lineCount = lineCount
    self.constructType = constructType
    self.constructName = constructName
    self.language = language
    self.score = score
    self.modulePath = modulePath
    self.featureTags = featureTags
    self.aiSummary = aiSummary
    self.aiTags = aiTags
    self.tokenCount = tokenCount
  }
}

/// RAG database status used by RAGToolsHandler
struct RAGToolStatus {
  let dbPath: String
  let exists: Bool
  let schemaVersion: Int
  let extensionLoaded: Bool
  let providerName: String
  let embeddingModelName: String
  let embeddingDimensions: Int
  let lastInitializedAt: Date?
  
  init(dbPath: String, exists: Bool, schemaVersion: Int, extensionLoaded: Bool, providerName: String, embeddingModelName: String, embeddingDimensions: Int, lastInitializedAt: Date?) {
    self.dbPath = dbPath
    self.exists = exists
    self.schemaVersion = schemaVersion
    self.extensionLoaded = extensionLoaded
    self.providerName = providerName
    self.embeddingModelName = embeddingModelName
    self.embeddingDimensions = embeddingDimensions
    self.lastInitializedAt = lastInitializedAt
  }
}

/// RAG indexing report used by RAGToolsHandler
struct RAGToolIndexReport {
  let repoId: String
  let repoPath: String
  let filesIndexed: Int
  let filesSkipped: Int
  let filesRemoved: Int
  let chunksIndexed: Int
  let bytesScanned: Int
  let durationMs: Int
  let embeddingCount: Int
  let embeddingDurationMs: Int
  let subReports: [RAGToolIndexReport]
  
  init(repoId: String, repoPath: String, filesIndexed: Int, filesSkipped: Int, filesRemoved: Int = 0, chunksIndexed: Int, bytesScanned: Int, durationMs: Int, embeddingCount: Int, embeddingDurationMs: Int, subReports: [RAGToolIndexReport] = []) {
    self.repoId = repoId
    self.repoPath = repoPath
    self.filesIndexed = filesIndexed
    self.filesSkipped = filesSkipped
    self.filesRemoved = filesRemoved
    self.chunksIndexed = chunksIndexed
    self.bytesScanned = bytesScanned
    self.durationMs = durationMs
    self.embeddingCount = embeddingCount
    self.embeddingDurationMs = embeddingDurationMs
    self.subReports = subReports
  }
}

/// RAG index progress used by RAGToolsHandler
enum RAGToolIndexProgress {
  case scanning(filesFound: Int)
  case indexing(current: Int, total: Int)
  case embedding(current: Int, total: Int)
  case complete(report: RAGToolIndexReport)
}

/// RAG repository info used by RAGToolsHandler
struct RAGToolRepoInfo {
  let id: String
  let name: String
  let rootPath: String
  let fileCount: Int
  let chunkCount: Int
  let lastIndexedAt: Date?
  let repoIdentifier: String?
  let parentRepoId: String?
  let embeddingModel: String?
  let embeddingDimensions: Int?
  
  init(id: String, name: String, rootPath: String, fileCount: Int, chunkCount: Int, lastIndexedAt: Date?, repoIdentifier: String? = nil, parentRepoId: String? = nil, embeddingModel: String? = nil, embeddingDimensions: Int? = nil) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.lastIndexedAt = lastIndexedAt
    self.repoIdentifier = repoIdentifier
    self.parentRepoId = parentRepoId
    self.embeddingModel = embeddingModel
    self.embeddingDimensions = embeddingDimensions
  }
}

/// RAG index statistics used by RAGToolsHandler
struct RAGToolIndexStats {
  let fileCount: Int
  let chunkCount: Int
  let embeddingCount: Int
  let totalLines: Int
  let dependencyCount: Int
  let dependenciesByType: [String: Int]
  
  init(fileCount: Int, chunkCount: Int, embeddingCount: Int, totalLines: Int, dependencyCount: Int = 0, dependenciesByType: [String: Int] = [:]) {
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.embeddingCount = embeddingCount
    self.totalLines = totalLines
    self.dependencyCount = dependencyCount
    self.dependenciesByType = dependenciesByType
  }
}

/// RAG large file info used by RAGToolsHandler
struct RAGToolLargeFile {
  let path: String
  let totalLines: Int
  let chunkCount: Int
  let language: String?
  
  init(path: String, totalLines: Int, chunkCount: Int, language: String?) {
    self.path = path
    self.totalLines = totalLines
    self.chunkCount = chunkCount
    self.language = language
  }
}

/// RAG construct type statistic used by RAGToolsHandler
struct RAGToolConstructTypeStat {
  let type: String
  let count: Int
  
  init(type: String, count: Int) {
    self.type = type
    self.count = count
  }
}

/// RAG overall stats used by RAGToolsHandler
struct RAGToolStats {
  let repoCount: Int
  let fileCount: Int
  let chunkCount: Int
  let embeddingCount: Int
  let cacheEmbeddingCount: Int
  let dbSizeBytes: Int
  let lastIndexedAt: Date?
  let lastIndexedRepoPath: String?
  
  init(repoCount: Int, fileCount: Int, chunkCount: Int, embeddingCount: Int, cacheEmbeddingCount: Int, dbSizeBytes: Int, lastIndexedAt: Date?, lastIndexedRepoPath: String?) {
    self.repoCount = repoCount
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.embeddingCount = embeddingCount
    self.cacheEmbeddingCount = cacheEmbeddingCount
    self.dbSizeBytes = dbSizeBytes
    self.lastIndexedAt = lastIndexedAt
    self.lastIndexedRepoPath = lastIndexedRepoPath
  }
}

/// RAG facet counts for filtering/grouping search results
struct RAGToolFacetCounts {
  let modulePaths: [(path: String, count: Int)]
  let featureTags: [(tag: String, count: Int)]
  let languages: [(language: String, count: Int)]
  let constructTypes: [(type: String, count: Int)]
  
  init(modulePaths: [(path: String, count: Int)], featureTags: [(tag: String, count: Int)], languages: [(language: String, count: Int)], constructTypes: [(type: String, count: Int)]) {
    self.modulePaths = modulePaths
    self.featureTags = featureTags
    self.languages = languages
    self.constructTypes = constructTypes
  }
}

/// RAG dependency result for dependency graph queries (Issue #176)
struct RAGToolDependencyResult {
  let sourceFile: String           // Relative path of source file
  let targetPath: String           // Module/path being depended on
  let targetFile: String?          // Resolved target file (if in repo)
  let dependencyType: String       // "import", "require", "inherit", "conform", "include", "extend"
  let rawImport: String            // Original import statement
  
  init(sourceFile: String, targetPath: String, targetFile: String?, dependencyType: String, rawImport: String) {
    self.sourceFile = sourceFile
    self.targetPath = targetPath
    self.targetFile = targetFile
    self.dependencyType = dependencyType
    self.rawImport = rawImport
  }
  
  /// Convert to dictionary for JSON response
  func toDict() -> [String: Any] {
    var dict: [String: Any] = [
      "sourceFile": sourceFile,
      "targetPath": targetPath,
      "dependencyType": dependencyType,
      "rawImport": rawImport
    ]
    if let targetFile {
      dict["targetFile"] = targetFile
    }
    return dict
  }
}

/// RAG orphan result for finding unused files (Issue #248)
struct RAGToolOrphanResult {
  let filePath: String
  let language: String
  let lineCount: Int
  let symbolsDefinedCount: Int
  let symbolsDefined: [String]
  let reason: String
  
  /// Convert to dictionary for JSON response
  func toDict() -> [String: Any] {
    return [
      "filePath": filePath,
      "language": language,
      "lineCount": lineCount,
      "symbolsDefinedCount": symbolsDefinedCount,
      "symbolsDefined": symbolsDefined,
      "reason": reason
    ]
  }
}

/// RAG structural query result for Issue #174
struct RAGToolStructuralResult {
  let path: String
  let language: String
  let lineCount: Int
  let methodCount: Int
  let byteSize: Int
  let modulePath: String?
  
  init(path: String, language: String, lineCount: Int, methodCount: Int, byteSize: Int, modulePath: String?) {
    self.path = path
    self.language = language
    self.lineCount = lineCount
    self.methodCount = methodCount
    self.byteSize = byteSize
    self.modulePath = modulePath
  }
}

/// RAG similar code result for Issue #175
struct RAGToolSimilarResult {
  let path: String
  let startLine: Int
  let endLine: Int
  let snippet: String
  let similarity: Double
  let constructType: String?
  let constructName: String?
  
  init(path: String, startLine: Int, endLine: Int, snippet: String, similarity: Double, constructType: String?, constructName: String?) {
    self.path = path
    self.startLine = startLine
    self.endLine = endLine
    self.snippet = snippet
    self.similarity = similarity
    self.constructType = constructType
    self.constructName = constructName
  }
}

