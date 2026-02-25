//
//  DoclingImportView.swift
//  Peel
//
//  Created on 2/5/26.
//

import SwiftUI

#if os(macOS)
import AppKit
import SwiftData

struct DoclingImportView: View {
  @Bindable var mcpServer: MCPServerService
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \PolicyCompany.name) private var companies: [PolicyCompany]
  @Query(sort: \PolicyPreset.name) private var presets: [PolicyPreset]
  @Query private var rules: [PolicyRule]
  @Query private var allDocuments: [PolicyDocument]

  @State private var inputPath = ""
  @State private var outputPath = ""
  @State private var pythonPath = ""
  @State private var scriptPath = ""
  @State private var profile = "high"
  @State private var selectedCompanyId: UUID?
  @State private var selectedPresetId: UUID?
  @State private var lastResult: DoclingService.ConvertResult?
  @State private var lastStoredMarkdownPath: String?
  @State private var lastDiagnostics: PolicyDiagnostics?
  @State private var lastViolations: [PolicyViolationSummary] = []
  @State private var lastError: String?
  @State private var isRunning = false
  @State private var indexStatus: String?
  @State private var conversionStatus = ""
  @State private var conversionStartTime: Date?
  @State private var conversionDuration: TimeInterval?

  private var service: DoclingService { mcpServer.doclingService }

  private var selectedCompany: PolicyCompany? {
    guard let selectedCompanyId else { return nil }
    return companies.first { $0.id == selectedCompanyId }
  }

  private var selectedPreset: PolicyPreset? {
    guard let selectedPresetId else { return nil }
    return presets.first { $0.id == selectedPresetId }
  }

  private var documentsForSelectedCompany: [PolicyDocument] {
    guard let selectedCompanyId else { return [] }
    return allDocuments
      .filter { $0.companyId == selectedCompanyId }
      .sorted { $0.importedAt > $1.importedAt }
  }

  private var versionHistoryHasDrift: Bool {
    let docs = documentsForSelectedCompany
    guard let baseline = docs.first(where: { $0.isBaseline }),
          let latest = docs.first,
          baseline.id != latest.id else { return false }
    return baseline.violationCount != latest.violationCount
  }

  var body: some View {
    ToolPageLayout {
      DoclingPolicyScopeView(
        companies: companies,
        presets: presets,
        selectedCompanyId: $selectedCompanyId,
        selectedPresetId: $selectedPresetId
      )

      DoclingImportFormView(
        inputPath: $inputPath,
        outputPath: $outputPath,
        profile: $profile,
        pythonPath: $pythonPath,
        scriptPath: $scriptPath,
        isRunning: isRunning,
        conversionStatus: conversionStatus,
        lastResult: lastResult,
        conversionDuration: conversionDuration,
        service: service,
        onConvert: { await runConvert() }
      )

      DoclingSetupView(
        pythonPath: $pythonPath,
        service: service,
        onError: { lastError = $0 }
      )

      DoclingRulesView(
        selectedCompanyId: selectedCompanyId,
        rules: rules
      )

      DoclingValidationView(
        lastResult: lastResult,
        lastStoredMarkdownPath: lastStoredMarkdownPath,
        selectedCompany: selectedCompany,
        selectedCompanyId: selectedCompanyId,
        rules: rules,
        presets: presets,
        indexStatus: indexStatus,
        lastDiagnostics: lastDiagnostics,
        conversionDuration: conversionDuration,
        documentsForSelectedCompany: documentsForSelectedCompany,
        versionHistoryHasDrift: versionHistoryHasDrift,
        lastError: lastError,
        lastViolations: $lastViolations
      )
    }
    .task {
      if pythonPath.isEmpty, let detected = service.suggestedPythonPath() {
        pythonPath = detected
      }
      if scriptPath.isEmpty, let detected = service.suggestedScriptPath() {
        scriptPath = detected
      }
      if presets.isEmpty {
        let preset = PolicyPreset(name: "Policy (High)", profile: "high")
        modelContext.insert(preset)
        try? modelContext.save()
      }
      if selectedPresetId == nil, let firstPreset = presets.first {
        selectedPresetId = firstPreset.id
        profile = firstPreset.profile
      }
      if selectedCompanyId == nil, let firstCompany = companies.first {
        selectedCompanyId = firstCompany.id
      }
    }
  }

  @MainActor
  private func runConvert() async {
    isRunning = true
    lastError = nil
    lastResult = nil
    lastStoredMarkdownPath = nil
    lastDiagnostics = nil
    lastViolations = []
    conversionStartTime = Date()
    conversionStatus = "Starting conversion…"
    defer {
      isRunning = false
      conversionDuration = Date().timeIntervalSince(conversionStartTime ?? Date())
      conversionStatus = ""
    }

    guard let company = selectedCompany else {
      lastError = "Select a company before converting."
      return
    }

    let activePreset = selectedPreset
    if let activePreset {
      profile = activePreset.profile
    }

    let options = DoclingService.Options(
      inputPath: inputPath,
      outputPath: outputPath,
      pythonPath: pythonPath.isEmpty ? nil : pythonPath,
      scriptPath: scriptPath.isEmpty ? nil : scriptPath,
      profile: profile
    )

    do {
      conversionStatus = "Converting PDF…"
      let result = try await service.runConvert(options: options)
      lastResult = result

      conversionStatus = "Storing document…"
      let storedPath = try storePolicyMarkdown(sourcePath: result.outputPath, company: company)
      lastStoredMarkdownPath = storedPath
      let diagnostics = computeDiagnostics(markdownPath: storedPath)
      lastDiagnostics = diagnostics

      let document = PolicyDocument(
        companyId: company.id,
        title: URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent,
        sourcePath: inputPath,
        markdownPath: storedPath,
        profile: profile
      )
      document.wordCount = diagnostics.wordCount
      document.headingCount = diagnostics.headingCount
      document.tableCount = diagnostics.tableCount
      document.listItemCount = diagnostics.listItemCount
      modelContext.insert(document)
      company.lastIndexedAt = Date()
      company.touch()
      try? modelContext.save()

      indexStatus = "Indexing…"
      conversionStatus = "Indexing…"
      do {
        _ = try await mcpServer.indexPolicyRepository(path: policyCompanyRoot(company: company).path)
        document.lastIndexedAt = Date()
        indexStatus = "Indexed"
        try? modelContext.save()
      } catch {
        indexStatus = "Index failed"
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func storePolicyMarkdown(sourcePath: String, company: PolicyCompany) throws -> String {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let destinationDir = policyCompanyRoot(company: company)
    try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
    let destinationURL = destinationDir.appendingPathComponent(sourceURL.lastPathComponent)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL.path
  }

  private func policyCompanyRoot(company: PolicyCompany) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let root = base?.appendingPathComponent("Peel").appendingPathComponent("Policies")
    return root?.appendingPathComponent(company.slug.isEmpty ? slugify(company.name) : company.slug) ?? URL(fileURLWithPath: NSTemporaryDirectory())
  }

  private func slugify(_ input: String) -> String {
    let lower = input.lowercased()
    let allowed = lower.map { char -> String in
      if char.isLetter || char.isNumber { return String(char) }
      return "-"
    }.joined()
    let collapsed = allowed.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private func computeDiagnostics(markdownPath: String) -> PolicyDiagnostics {
    let text = (try? String(contentsOfFile: markdownPath, encoding: .utf8)) ?? ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let words = text.split { $0.isWhitespace || $0.isNewline }
    let headingCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
    let tableCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }.count
    let listItemCount = lines.filter { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.range(of: "^\\d+\\.", options: .regularExpression) != nil
    }.count
    return PolicyDiagnostics(
      wordCount: words.count,
      headingCount: headingCount,
      tableCount: tableCount,
      listItemCount: listItemCount
    )
  }
}
#else
struct DoclingImportView: View {
  var body: some View {
    Text("Docling import is available on macOS.")
      .foregroundStyle(.secondary)
  }
}
#endif
