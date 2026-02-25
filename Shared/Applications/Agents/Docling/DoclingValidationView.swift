//
//  DoclingValidationView.swift
//  Peel
//

import SwiftUI

#if os(macOS)
import AppKit
import SwiftData

struct PolicyDiagnostics {
  let wordCount: Int
  let headingCount: Int
  let tableCount: Int
  let listItemCount: Int
}

struct PolicyViolationSummary: Identifiable {
  let id: UUID = UUID()
  let ruleId: UUID
  let ruleName: String
  let severity: String
  let lineNumber: Int
  let snippet: String
}

struct DoclingValidationView: View {
  let lastResult: DoclingService.ConvertResult?
  let lastStoredMarkdownPath: String?
  let selectedCompany: PolicyCompany?
  let selectedCompanyId: UUID?
  let rules: [PolicyRule]
  let presets: [PolicyPreset]
  let indexStatus: String?
  let lastDiagnostics: PolicyDiagnostics?
  let conversionDuration: TimeInterval?
  let documentsForSelectedCompany: [PolicyDocument]
  let versionHistoryHasDrift: Bool
  let lastError: String?
  @Binding var lastViolations: [PolicyViolationSummary]
  @Environment(\.modelContext) private var modelContext

  @State private var exportStatus: String?
  @State private var isExporting = false
  @State private var showVersionHistory = false
  @State private var compareDocA: PolicyDocument?
  @State private var compareDocB: PolicyDocument?
  @State private var showDiff = false
  @State private var showImportPreview = false
  @State private var pendingImportPackage: PolicyPackage?

  private var rulesForSelectedCompany: [PolicyRule] {
    guard let selectedCompanyId else { return [] }
    return rules.filter { $0.companyId == selectedCompanyId && $0.isEnabled }
  }

  var body: some View {
    Group {
      ToolSection("Validation") {
        HStack(spacing: 8) {
          Button("Run Validation") {
            Task { await runValidation() }
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.runValidation")

          if let indexStatus {
            Text(indexStatus)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if lastViolations.isEmpty {
          Text("No violations detected")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("\(lastViolations.count) violation(s) found")
            .font(.caption)
            .foregroundStyle(.secondary)
          ForEach(lastViolations) { violation in
            DisclosureGroup {
              Text(violation.snippet)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 16)
            } label: {
              HStack(spacing: 6) {
                Circle()
                  .fill(severityColor(violation.severity))
                  .frame(width: 8, height: 8)
                Text(violation.ruleName)
                  .font(.caption)
                  .bold()
                Spacer()
                Text("L\(violation.lineNumber)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      ToolSection("Export / Share") {
        HStack(spacing: 8) {
          Button(isExporting ? "Exporting..." : "Export Policy Package") {
            Task { await exportPolicyPackage() }
          }
          .buttonStyle(.bordered)
          .disabled(isExporting)
          .accessibilityIdentifier("agents.docling.exportPackage")

          Button("Import Policy Package") {
            importPolicyPackage()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.importPackage")
        }

        if let exportStatus {
          Text(exportStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let lastError {
        VStack(alignment: .leading, spacing: 4) {
          Label(lastError, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
          if let guidance = errorGuidance(for: lastError) {
            Text("💡 \(guidance)")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
      }

      if let lastDiagnostics {
        ToolSection("Diagnostics") {
          Text("Words: \(lastDiagnostics.wordCount)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Headings: \(lastDiagnostics.headingCount)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Tables: \(lastDiagnostics.tableCount)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("List items: \(lastDiagnostics.listItemCount)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let company = selectedCompany, !documentsForSelectedCompany.isEmpty {
        ToolSection("Version History") {
          Text("\(documentsForSelectedCompany.count) version(s) for \(company.name)")
            .font(.caption)
            .foregroundStyle(.secondary)

          if versionHistoryHasDrift {
            Label("Drift detected: current version differs from baseline", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }

          Button("Show History") {
            showVersionHistory = true
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .sheet(isPresented: $showVersionHistory) {
      if let company = selectedCompany {
        PolicyVersionHistoryView(
          company: company,
          compareDocA: $compareDocA,
          compareDocB: $compareDocB,
          showDiff: $showDiff
        )
        .environment(\.modelContext, modelContext)
      }
    }
    .sheet(isPresented: $showDiff) {
      if let a = compareDocA, let b = compareDocB {
        PolicyDiffView(docA: a, docB: b)
      }
    }
    .sheet(isPresented: $showImportPreview) {
      if let pkg = pendingImportPackage {
        PolicyImportPreviewSheet(
          package: pkg,
          modelContext: modelContext,
          onDismiss: { showImportPreview = false }
        )
      }
    }
  }

  @MainActor
  private func runValidation() async {
    lastViolations = []
    guard let lastResult else { return }
    let markdownPath = lastStoredMarkdownPath ?? lastResult.outputPath
    guard let company = selectedCompany else { return }
    let activeRules = rulesForSelectedCompany
    guard !activeRules.isEmpty else { return }

    let violations = validateMarkdown(path: markdownPath, rules: activeRules)
    lastViolations = violations

    if let document = fetchLatestDocument(for: company) {
      let existing = fetchViolations(for: document)
      for violation in existing {
        modelContext.delete(violation)
      }
      document.lastValidatedAt = Date()
      document.violationCount = violations.count
      try? modelContext.save()
      for violation in violations {
        let record = PolicyViolation(
          documentId: document.id,
          ruleId: violation.ruleId,
          lineNumber: violation.lineNumber,
          snippet: violation.snippet
        )
        modelContext.insert(record)
      }
      try? modelContext.save()
    }
  }

  @MainActor
  private func exportPolicyPackage() async {
    guard let company = selectedCompany else {
      exportStatus = "Select a company first"
      return
    }
    isExporting = true
    defer { isExporting = false }

    let companyId = company.id
    let allRules = rules.filter { $0.companyId == companyId }
    let companyDocuments: [PolicyDocument] = {
      let descriptor = FetchDescriptor<PolicyDocument>(
        predicate: #Predicate { $0.companyId == companyId }
      )
      return (try? modelContext.fetch(descriptor)) ?? []
    }()

    do {
      let data = try PolicyExportService().exportPackage(
        company: company,
        documents: companyDocuments,
        rules: allRules,
        presets: Array(presets)
      )
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "\(company.slug)-policy-package.json"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      try data.write(to: url)
      exportStatus = "Exported to \(url.lastPathComponent)"
    } catch {
      exportStatus = error.localizedDescription
    }
  }

  private func importPolicyPackage() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      let package = try PolicyExportService().importPackage(from: data)
      pendingImportPackage = package
      showImportPreview = true
    } catch {
      exportStatus = "Import failed: \(error.localizedDescription)"
    }
  }

  private func fetchLatestDocument(for company: PolicyCompany) -> PolicyDocument? {
    let companyId = company.id
    let descriptor = FetchDescriptor<PolicyDocument>(
      predicate: #Predicate { $0.companyId == companyId },
      sortBy: [SortDescriptor(\.importedAt, order: .reverse)]
    )
    return try? modelContext.fetch(descriptor).first
  }

  private func fetchViolations(for document: PolicyDocument) -> [PolicyViolation] {
    let documentId = document.id
    let descriptor = FetchDescriptor<PolicyViolation>(
      predicate: #Predicate { $0.documentId == documentId }
    )
    return (try? modelContext.fetch(descriptor)) ?? []
  }

  private func validateMarkdown(path: String, rules: [PolicyRule]) -> [PolicyViolationSummary] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var results: [PolicyViolationSummary] = []

    for rule in rules {
      guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
      for (index, line) in lines.enumerated() {
        let lineString = String(line)
        let range = NSRange(location: 0, length: lineString.utf16.count)
        if regex.firstMatch(in: lineString, options: [], range: range) != nil {
          results.append(PolicyViolationSummary(
            ruleId: rule.id,
            ruleName: rule.name,
            severity: rule.severity,
            lineNumber: index + 1,
            snippet: lineString.trimmingCharacters(in: .whitespacesAndNewlines)
          ))
        }
      }
    }
    return results
  }

  private func severityColor(_ severity: String) -> Color {
    switch severity.lowercased() {
    case "critical": return .red
    case "warning": return .orange
    case "info": return .blue
    default: return .secondary
    }
  }

  private func errorGuidance(for error: String) -> String? {
    if error.contains("python3 not found") || error.contains("Install Python") {
      return "Install Python 3.10+ via Homebrew: brew install python@3.11"
    }
    if error.contains("not found") && error.contains("docling-convert.py") {
      return "Run 'Install Docling' in Setup, or set the script path manually."
    }
    if error.contains("No module named 'docling'") {
      return "Docling is not installed. Click 'Install Docling' in the Setup section."
    }
    if error.contains("Select a company") {
      return "Add a company in the Policy Scope section first."
    }
    return nil
  }
}
#endif
