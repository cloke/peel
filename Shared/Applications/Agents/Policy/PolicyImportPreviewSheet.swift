//
//  PolicyImportPreviewSheet.swift
//  Peel
//
//  Created on 2/19/26.
//

import SwiftUI

import AppKit
import SwiftData

struct PolicyImportPreviewSheet: View {
  let package: PolicyPackage
  let modelContext: ModelContext
  let onDismiss: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var conflictResolution: ConflictResolution = .merge

  @Query(sort: \PolicyCompany.name) private var existingCompanies: [PolicyCompany]
  @Query private var existingRules: [PolicyRule]
  @Query private var existingPresets: [PolicyPreset]

  enum ConflictResolution {
    case merge
    case createNew
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Import Policy Package")
        .font(.title2)
        .fontWeight(.semibold)

      packageSummarySection

      if let conflict = conflictingCompany {
        conflictSection(existingCompany: conflict)
      }

      Spacer()

      HStack {
        Button("Apply") {
          applyImport()
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("agents.docling.importApply")

        Button("Cancel") {
          onDismiss()
          dismiss()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("agents.docling.importCancel")
      }
    }
    .padding(24)
    .frame(minWidth: 480, minHeight: 360)
  }

  private var packageSummarySection: some View {
    GroupBox("Package Contents") {
      VStack(alignment: .leading, spacing: 6) {
        LabeledContent("Company", value: package.company.name)
        LabeledContent("Documents", value: "\(package.documents.count) document(s)")
        LabeledContent("Rules", value: "\(package.rules.count) rule(s)")
        LabeledContent("Presets", value: "\(package.presets.count) preset(s)")
        LabeledContent("Exported", value: package.exportedAt.formatted(date: .abbreviated, time: .shortened))
      }
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func conflictSection(existingCompany: PolicyCompany) -> some View {
    GroupBox("Conflict Detected") {
      VStack(alignment: .leading, spacing: 8) {
        Text("A company named '\(existingCompany.name)' already exists.")
          .foregroundStyle(.orange)

        Picker("Conflict resolution", selection: $conflictResolution) {
          Text("Merge").tag(ConflictResolution.merge)
          Text("Create New").tag(ConflictResolution.createNew)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if conflictResolution == .merge {
          Text("Rules and presets will be added. Existing items with the same name will be skipped.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("A new company will be created with a unique slug.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
  }

  private var conflictingCompany: PolicyCompany? {
    existingCompanies.first { $0.slug == package.company.slug }
  }

  @MainActor
  private func applyImport() {
    let company: PolicyCompany
    if let existing = conflictingCompany {
      switch conflictResolution {
      case .merge:
        company = existing
      case .createNew:
        let newSlug = "\(package.company.slug)-\(UUID().uuidString.prefix(8).lowercased())"
        company = PolicyCompany(name: package.company.name, slug: newSlug)
        modelContext.insert(company)
      }
    } else {
      company = PolicyCompany(name: package.company.name, slug: package.company.slug)
      modelContext.insert(company)
    }

    let existingRuleNames = Set(existingRules.filter { $0.companyId == company.id }.map { $0.name })
    for pkgRule in package.rules {
      guard !existingRuleNames.contains(pkgRule.name) else { continue }
      let rule = PolicyRule(
        companyId: company.id,
        name: pkgRule.name,
        detail: pkgRule.detail,
        severity: pkgRule.severity,
        pattern: pkgRule.pattern
      )
      rule.isEnabled = pkgRule.isEnabled
      modelContext.insert(rule)
    }

    let existingPresetNames = Set(existingPresets.map { $0.name })
    for pkgPreset in package.presets {
      guard !existingPresetNames.contains(pkgPreset.name) else { continue }
      let preset = PolicyPreset(
        name: pkgPreset.name,
        profile: pkgPreset.profile,
        imagesScale: pkgPreset.imagesScale,
        doOCR: pkgPreset.doOCR,
        doTables: pkgPreset.doTables,
        doCode: pkgPreset.doCode,
        doFormula: pkgPreset.doFormula
      )
      modelContext.insert(preset)
    }

    let companyRoot = policyCompanyRoot(company: company)
    for pkgDoc in package.documents {
      let destDir = companyRoot
      try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
      let destURL = destDir.appendingPathComponent("\(pkgDoc.title).md")
      try? pkgDoc.markdownContent.write(to: destURL, atomically: true, encoding: .utf8)

      let document = PolicyDocument(
        companyId: company.id,
        title: pkgDoc.title,
        sourcePath: pkgDoc.sourcePath,
        markdownPath: destURL.path,
        profile: pkgDoc.profile
      )
      document.wordCount = pkgDoc.wordCount
      document.headingCount = pkgDoc.headingCount
      document.tableCount = pkgDoc.tableCount
      document.listItemCount = pkgDoc.listItemCount
      document.importedAt = pkgDoc.importedAt
      modelContext.insert(document)
    }

    try? modelContext.save()
  }

  private func policyCompanyRoot(company: PolicyCompany) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let root = base?.appendingPathComponent("Peel").appendingPathComponent("Policies")
    return root?.appendingPathComponent(company.slug.isEmpty ? company.name : company.slug)
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
  }
}
