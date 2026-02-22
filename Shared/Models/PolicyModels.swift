//
//  PolicyModels.swift
//  Peel
//
//  Policy/Docling-related SwiftData models (device-local, not synced to iCloud).
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

/// Company scope for policy documents.
@Model
final class PolicyCompany {
  var id: UUID = UUID()
  var name: String = ""
  var slug: String = ""
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var lastIndexedAt: Date?

  init(name: String, slug: String) {
    self.id = UUID()
    self.name = name
    self.slug = slug
    self.createdAt = Date()
    self.updatedAt = Date()
  }

  func touch() {
    updatedAt = Date()
  }
}

/// A single imported policy document.
@Model
final class PolicyDocument {
  var id: UUID = UUID()
  var companyId: UUID = UUID()
  var title: String = ""
  var sourcePath: String = ""
  var markdownPath: String = ""
  var profile: String = "high"
  var importedAt: Date = Date()
  var lastIndexedAt: Date?
  var wordCount: Int = 0
  var headingCount: Int = 0
  var tableCount: Int = 0
  var listItemCount: Int = 0
  var lastValidatedAt: Date?
  var violationCount: Int = 0
  var isBaseline: Bool = false

  init(
    companyId: UUID,
    title: String,
    sourcePath: String,
    markdownPath: String,
    profile: String
  ) {
    self.id = UUID()
    self.companyId = companyId
    self.title = title
    self.sourcePath = sourcePath
    self.markdownPath = markdownPath
    self.profile = profile
    self.importedAt = Date()
  }
}

/// Validation rule for a company policy.
@Model
final class PolicyRule {
  var id: UUID = UUID()
  var companyId: UUID = UUID()
  var name: String = ""
  var detail: String = ""
  var severity: String = "warning"
  var pattern: String = ""
  var isEnabled: Bool = true
  var createdAt: Date = Date()

  init(companyId: UUID, name: String, detail: String = "", severity: String = "warning", pattern: String) {
    self.id = UUID()
    self.companyId = companyId
    self.name = name
    self.detail = detail
    self.severity = severity
    self.pattern = pattern
    self.isEnabled = true
    self.createdAt = Date()
  }
}

/// Validation violation for a document.
@Model
final class PolicyViolation {
  var id: UUID = UUID()
  var documentId: UUID = UUID()
  var ruleId: UUID = UUID()
  var lineNumber: Int = 0
  var snippet: String = ""
  var createdAt: Date = Date()

  init(documentId: UUID, ruleId: UUID, lineNumber: Int, snippet: String) {
    self.id = UUID()
    self.documentId = documentId
    self.ruleId = ruleId
    self.lineNumber = lineNumber
    self.snippet = snippet
    self.createdAt = Date()
  }
}

/// Preset for Docling conversions.
@Model
final class PolicyPreset {
  var id: UUID = UUID()
  var name: String = ""
  var profile: String = "high"
  var imagesScale: Double = 2.0
  var doOCR: Bool = true
  var doTables: Bool = true
  var doCode: Bool = true
  var doFormula: Bool = true
  var createdAt: Date = Date()

  init(
    name: String,
    profile: String,
    imagesScale: Double = 2.0,
    doOCR: Bool = true,
    doTables: Bool = true,
    doCode: Bool = true,
    doFormula: Bool = true
  ) {
    self.id = UUID()
    self.name = name
    self.profile = profile
    self.imagesScale = imagesScale
    self.doOCR = doOCR
    self.doTables = doTables
    self.doCode = doCode
    self.doFormula = doFormula
    self.createdAt = Date()
  }
}
