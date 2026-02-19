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
  @State private var inputPath = ""
  @State private var outputPath = ""
  @State private var pythonPath = ""
  @State private var scriptPath = ""
  @State private var profile = "high"
  @State private var selectedCompanyId: UUID?
  @State private var newCompanyName = ""
  @State private var selectedPresetId: UUID?
  @State private var newPresetName = ""
  @State private var newPresetProfile = "high"
  @State private var newPresetImagesScale: Double = 2.0
  @State private var newPresetOCR = true
  @State private var newPresetTables = true
  @State private var newPresetCode = true
  @State private var newPresetFormula = true
  @State private var newRuleName = ""
  @State private var newRulePattern = ""
  @State private var newRuleSeverity = "warning"
  @State private var lastResult: DoclingService.ConvertResult?
  @State private var lastStoredMarkdownPath: String?
  @State private var lastDiagnostics: PolicyDiagnostics?
  @State private var lastViolations: [PolicyViolationSummary] = []
  @State private var lastError: String?
  @State private var isRunning = false
  @State private var isInstalling = false
  @State private var installLog: String?
  @State private var installStatus: String?
  @State private var indexStatus: String?
  @State private var showVersionHistory = false
  @State private var compareDocA: PolicyDocument?
  @State private var compareDocB: PolicyDocument?
  @State private var showDiff = false
  @State private var exportStatus: String?
  @State private var isExporting = false
  @State private var showImportPreview = false
  @State private var pendingImportPackage: PolicyPackage?

  @Query private var allDocuments: [PolicyDocument]

  private var service: DoclingService { mcpServer.doclingService }

  var body: some View {
    ToolPageLayout {
      ToolSection("Policy Scope") {
        LabeledContent("Company") {
          Picker("Company", selection: $selectedCompanyId) {
            Text("Select...").tag(UUID?.none)
            ForEach(companies, id: \.id) { company in
              Text(company.name).tag(UUID?.some(company.id))
            }
          }
          .labelsHidden()
          .frame(minWidth: 240)
          .accessibilityIdentifier("agents.docling.company")
        }

        LabeledContent("New company") {
          HStack(spacing: 8) {
            TextField("Acme Corp", text: $newCompanyName)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 240)
              .accessibilityIdentifier("agents.docling.newCompany")

            Button("Add") {
              addCompany()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.docling.addCompany")
          }
        }
      }

      ToolSection("Presets") {
        LabeledContent("Active preset") {
          Picker("Preset", selection: $selectedPresetId) {
            Text("Select...").tag(UUID?.none)
            ForEach(presets, id: \.id) { preset in
              Text(preset.name).tag(UUID?.some(preset.id))
            }
          }
          .labelsHidden()
          .frame(minWidth: 240)
          .accessibilityIdentifier("agents.docling.preset")
        }

        LabeledContent("New preset") {
          TextField("Policy (High)", text: $newPresetName)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240)
            .accessibilityIdentifier("agents.docling.newPreset")
        }

        LabeledContent("Profile") {
          Picker("Profile", selection: $newPresetProfile) {
            Text("High").tag("high")
            Text("Standard").tag("standard")
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 220)
          .accessibilityIdentifier("agents.docling.newPresetProfile")
        }

        LabeledContent("Images scale") {
          Slider(value: $newPresetImagesScale, in: 1.0...3.0, step: 0.25)
            .frame(width: 220)
            .accessibilityIdentifier("agents.docling.newPresetImagesScale")
        }

        Toggle("OCR", isOn: $newPresetOCR)
          .accessibilityIdentifier("agents.docling.newPresetOCR")
        Toggle("Tables", isOn: $newPresetTables)
          .accessibilityIdentifier("agents.docling.newPresetTables")
        Toggle("Code", isOn: $newPresetCode)
          .accessibilityIdentifier("agents.docling.newPresetCode")
        Toggle("Formulas", isOn: $newPresetFormula)
          .accessibilityIdentifier("agents.docling.newPresetFormula")

        HStack(spacing: 8) {
          Button("Save Preset") {
            addPreset()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.savePreset")

          if let selectedPresetId,
             let preset = presets.first(where: { $0.id == selectedPresetId }) {
            Text("Using: \(preset.name)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      ToolSection("Docling Import") {
        LabeledContent("Input PDF") {
          HStack(spacing: 8) {
            TextField("/path/to/policy.pdf", text: $inputPath)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 320)
              .accessibilityIdentifier("agents.docling.inputPath")

            Button("Browse") {
              selectInputPDF()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.docling.browseInput")
          }
        }

        LabeledContent("Output Markdown") {
          HStack(spacing: 8) {
            TextField("/path/to/policy.md", text: $outputPath)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 320)
              .accessibilityIdentifier("agents.docling.outputPath")

            Button("Browse") {
              selectOutputFile()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.docling.browseOutput")

            Button("Output Dir") {
              selectOutputDirectory()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.docling.browseOutputDir")
          }
        }

        LabeledContent("Profile") {
          Picker("Profile", selection: $profile) {
            Text("High").tag("high")
            Text("Standard").tag("standard")
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 220)
          .accessibilityIdentifier("agents.docling.profile")
        }

        LabeledContent("Python path (optional)") {
          HStack(spacing: 8) {
            TextField("Auto-detect", text: $pythonPath)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 320)
              .accessibilityIdentifier("agents.docling.pythonPath")

            Button("Detect") {
              if let detected = service.suggestedPythonPath() {
                pythonPath = detected
              }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.docling.detectPython")
          }
        }

        LabeledContent("Script path (optional)") {
          HStack(spacing: 8) {
            TextField("Auto-detect", text: $scriptPath)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 320)
              .accessibilityIdentifier("agents.docling.scriptPath")

            Button("Detect") {
              if let detected = service.suggestedScriptPath() {
                scriptPath = detected
              }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.docling.detectScript")
          }
        }

        HStack(spacing: 8) {
          Button(isRunning ? "Converting..." : "Convert") {
            Task { await runConvert() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isRunning)
          .accessibilityIdentifier("agents.docling.convert")

          if let lastResult {
            Button("Open Output") {
              openOutput(at: lastResult.outputPath)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.docling.openOutput")
          }
        }
      }

      ToolSection("Setup") {
        HStack(spacing: 8) {
          Button(isInstalling ? "Installing..." : "Install Docling") {
            Task { await installDocling() }
          }
          .buttonStyle(.bordered)
          .disabled(isInstalling)
          .accessibilityIdentifier("agents.docling.install")

          Button("Open Guide") {
            openGuide()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.openGuide")

          if let installStatus {
            Text(installStatus)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let installLog {
          Text(installLog)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      ToolSection("Rules") {
        if rulesForSelectedCompany.isEmpty {
          Text("No rules yet")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(rulesForSelectedCompany, id: \.id) { rule in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                Text(rule.pattern)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(rule.severity)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        LabeledContent("New rule") {
          TextField("Rule name", text: $newRuleName)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240)
            .accessibilityIdentifier("agents.docling.newRuleName")
        }

        LabeledContent("Pattern") {
          TextField("regex or phrase", text: $newRulePattern)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240)
            .accessibilityIdentifier("agents.docling.newRulePattern")
        }

        LabeledContent("Severity") {
          Picker("Severity", selection: $newRuleSeverity) {
            Text("info").tag("info")
            Text("warning").tag("warning")
            Text("critical").tag("critical")
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 220)
          .accessibilityIdentifier("agents.docling.newRuleSeverity")
        }

        Button("Add Rule") {
          addRule()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("agents.docling.addRule")
      }

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
          ForEach(lastViolations) { violation in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(violation.severity.uppercased()): \(violation.ruleName)")
                .font(.caption)
              Text("Line \(violation.lineNumber): \(violation.snippet)")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        Text(lastError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if let lastResult {
        ToolSection("Last Conversion") {
          Text("Output: \(lastResult.outputPath)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Bytes written: \(lastResult.bytesWritten)")
            .font(.caption)
            .foregroundStyle(.secondary)
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
      let available = await service.isDoclingAvailable(pythonPath: pythonPath.isEmpty ? nil : pythonPath)
      installStatus = available ? "Ready" : "Not installed"
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

  @MainActor
  private func runConvert() async {
    isRunning = true
    lastError = nil
    lastResult = nil
    lastStoredMarkdownPath = nil
    lastDiagnostics = nil
    lastViolations = []
    defer { isRunning = false }

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
      let result = try await service.runConvert(options: options)
      lastResult = result

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

  @MainActor
  private func installDocling() async {
    isInstalling = true
    lastError = nil
    installLog = nil
    installStatus = nil
    defer { isInstalling = false }

    do {
      let result = try await service.ensureDoclingInstalled(pythonPath: pythonPath.isEmpty ? nil : pythonPath)
      pythonPath = result.pythonPath
      installLog = result.log
      installStatus = "Installed"
    } catch {
      lastError = error.localizedDescription
      installStatus = "Install failed"
    }
  }

  private func openOutput(at path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  private func openGuide() {
    let fm = FileManager.default
    var candidates: [String] = []
    candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Docs/guides/DOCLING_POLICY_WORKFLOW.md").path)
    candidates.append(URL(fileURLWithPath: fm.homeDirectoryForCurrentUser.path).appendingPathComponent("code/peel/Docs/guides/DOCLING_POLICY_WORKFLOW.md").path)
    if let bundle = Bundle.main.resourceURL {
      candidates.append(bundle.appendingPathComponent("Docs/guides/DOCLING_POLICY_WORKFLOW.md").path)
    }

    for path in candidates {
      if fm.fileExists(atPath: path) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return
      }
    }

    if let url = URL(string: "https://raw.githubusercontent.com/cloke/peel/main/Docs/guides/DOCLING_POLICY_WORKFLOW.md") {
      NSWorkspace.shared.open(url)
    }
  }

  private var selectedCompany: PolicyCompany? {
    guard let selectedCompanyId else { return nil }
    return companies.first { $0.id == selectedCompanyId }
  }

  private var selectedPreset: PolicyPreset? {
    guard let selectedPresetId else { return nil }
    return presets.first { $0.id == selectedPresetId }
  }

  private var rulesForSelectedCompany: [PolicyRule] {
    guard let selectedCompanyId else { return [] }
    return rules.filter { $0.companyId == selectedCompanyId && $0.isEnabled }
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

  private func addCompany() {
    let trimmed = newCompanyName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let slug = slugify(trimmed)
    let company = PolicyCompany(name: trimmed, slug: slug)
    modelContext.insert(company)
    try? modelContext.save()
    selectedCompanyId = company.id
    newCompanyName = ""
  }

  private func addPreset() {
    let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let preset = PolicyPreset(
      name: trimmed,
      profile: newPresetProfile,
      imagesScale: newPresetImagesScale,
      doOCR: newPresetOCR,
      doTables: newPresetTables,
      doCode: newPresetCode,
      doFormula: newPresetFormula
    )
    modelContext.insert(preset)
    try? modelContext.save()
    selectedPresetId = preset.id
    newPresetName = ""
  }

  private func addRule() {
    guard let selectedCompanyId else { return }
    let name = newRuleName.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = newRulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !pattern.isEmpty else { return }
    let rule = PolicyRule(
      companyId: selectedCompanyId,
      name: name,
      detail: "",
      severity: newRuleSeverity,
      pattern: pattern
    )
    modelContext.insert(rule)
    try? modelContext.save()
    newRuleName = ""
    newRulePattern = ""
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

  private func selectInputPDF() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.pdf]
    if panel.runModal() == .OK, let url = panel.url {
      inputPath = url.path
      if outputPath.isEmpty {
        outputPath = url.deletingPathExtension().appendingPathExtension("md").path
      }
    }
  }

  private func selectOutputFile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = suggestedOutputFilename()
    if panel.runModal() == .OK, let url = panel.url {
      outputPath = url.path
    }
  }

  private func selectOutputDirectory() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    if panel.runModal() == .OK, let url = panel.url {
      outputPath = url.appendingPathComponent(suggestedOutputFilename()).path
    }
  }

  private func suggestedOutputFilename() -> String {
    let inputURL = URL(fileURLWithPath: inputPath.isEmpty ? "output.pdf" : inputPath)
    let base = inputURL.deletingPathExtension().lastPathComponent
    return base.isEmpty ? "output.md" : "\(base).md"
  }
}
private struct PolicyDiagnostics {
  let wordCount: Int
  let headingCount: Int
  let tableCount: Int
  let listItemCount: Int
}

private struct PolicyViolationSummary: Identifiable {
  let id: UUID = UUID()
  let ruleId: UUID
  let ruleName: String
  let severity: String
  let lineNumber: Int
  let snippet: String
}
#else
struct DoclingImportView: View {
  var body: some View {
    Text("Docling import is available on macOS.")
      .foregroundStyle(.secondary)
  }
}
#endif
