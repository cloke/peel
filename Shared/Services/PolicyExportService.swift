//
//  PolicyExportService.swift
//  Peel
//
//  Created on 2/19/26.
//

import Foundation

// MARK: - Package Model

struct PolicyPackage: Codable {
  var version: Int = 1
  var exportedAt: Date
  var company: PolicyPackageCompany
  var documents: [PolicyPackageDocument]
  var rules: [PolicyPackageRule]
  var presets: [PolicyPackagePreset]
}

struct PolicyPackageCompany: Codable {
  var id: UUID
  var name: String
  var slug: String
  var createdAt: Date
  var updatedAt: Date
}

struct PolicyPackageDocument: Codable {
  var id: UUID
  var title: String
  var sourcePath: String
  var profile: String
  var importedAt: Date
  var wordCount: Int
  var headingCount: Int
  var tableCount: Int
  var listItemCount: Int
  var markdownContent: String
}

struct PolicyPackageRule: Codable {
  var id: UUID
  var name: String
  var detail: String
  var severity: String
  var pattern: String
  var isEnabled: Bool
  var createdAt: Date
}

struct PolicyPackagePreset: Codable {
  var id: UUID
  var name: String
  var profile: String
  var imagesScale: Double
  var doOCR: Bool
  var doTables: Bool
  var doCode: Bool
  var doFormula: Bool
  var createdAt: Date
}

// MARK: - Service

struct PolicyExportService {
  struct ExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  func exportPackage(
    company: PolicyCompany,
    documents: [PolicyDocument],
    rules: [PolicyRule],
    presets: [PolicyPreset]
  ) throws -> Data {
    let packageCompany = PolicyPackageCompany(
      id: company.id,
      name: company.name,
      slug: company.slug,
      createdAt: company.createdAt,
      updatedAt: company.updatedAt
    )

    let packageDocuments: [PolicyPackageDocument] = documents.map { doc in
      let content: String
      if doc.markdownPath.isEmpty {
        content = ""
      } else {
        content = (try? String(contentsOfFile: doc.markdownPath, encoding: .utf8)) ?? ""
      }
      return PolicyPackageDocument(
        id: doc.id,
        title: doc.title,
        sourcePath: doc.sourcePath,
        profile: doc.profile,
        importedAt: doc.importedAt,
        wordCount: doc.wordCount,
        headingCount: doc.headingCount,
        tableCount: doc.tableCount,
        listItemCount: doc.listItemCount,
        markdownContent: content
      )
    }

    let packageRules: [PolicyPackageRule] = rules.map { rule in
      PolicyPackageRule(
        id: rule.id,
        name: rule.name,
        detail: rule.detail,
        severity: rule.severity,
        pattern: rule.pattern,
        isEnabled: rule.isEnabled,
        createdAt: rule.createdAt
      )
    }

    let packagePresets: [PolicyPackagePreset] = presets.map { preset in
      PolicyPackagePreset(
        id: preset.id,
        name: preset.name,
        profile: preset.profile,
        imagesScale: preset.imagesScale,
        doOCR: preset.doOCR,
        doTables: preset.doTables,
        doCode: preset.doCode,
        doFormula: preset.doFormula,
        createdAt: preset.createdAt
      )
    }

    let package = PolicyPackage(
      exportedAt: Date(),
      company: packageCompany,
      documents: packageDocuments,
      rules: packageRules,
      presets: packagePresets
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(package)
  }

  func importPackage(from data: Data) throws -> PolicyPackage {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PolicyPackage.self, from: data)
  }
}
