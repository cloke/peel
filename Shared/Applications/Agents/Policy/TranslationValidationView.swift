//
//  TranslationValidationView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI
struct TranslationValidationView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @State private var rootPath = ""
  @State private var translationsPath = ""
  @State private var baseLocale = ""
  @State private var toolPath = ""
  @State private var lastDetectedToolPath: String?
  @State private var showSummaryOnly = true
  @State private var filterMissing = true
  @State private var filterExtra = true
  @State private var filterPlaceholders = false
  @State private var filterTypes = false
  @State private var filterSuspects = false
  @State private var useAppleAI = false
  @State private var redactSamples = true
  @State private var showingRootConfirm = false
  @State private var pendingOptions: TranslationValidatorService.Options?

  private var service: TranslationValidatorService { mcpServer.translationValidatorService }

  private var selectedOnly: String? {
    let kinds: [String] = [
      filterMissing ? IssueKind.missing.rawValue : nil,
      filterExtra ? IssueKind.extra.rawValue : nil,
      filterPlaceholders ? IssueKind.placeholders.rawValue : nil,
      filterTypes ? IssueKind.types.rawValue : nil,
      filterSuspects ? IssueKind.suspects.rawValue : nil
    ].compactMap { $0 }

    return kinds.isEmpty ? nil : kinds.joined(separator: ",")
  }

  var body: some View {
    ToolPageLayout {
      ToolSection("Translation Validator") {
        LabeledContent("Project root") {
          TextField("/path/to/project", text: $rootPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.translationValidator.rootPath")
        }

        LabeledContent("Translations path (optional)") {
          TextField("/path/to/translations", text: $translationsPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.translationValidator.translationsPath")
        }

        LabeledContent("Base locale (optional)") {
          TextField("en-us", text: $baseLocale)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
            .accessibilityIdentifier("agents.translationValidator.baseLocale")
        }

        LabeledContent("Validator path (optional)") {
          HStack(spacing: 8) {
            TextField("Auto-detect from app project", text: $toolPath)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 320)
              .accessibilityIdentifier("agents.translationValidator.toolPath")

            Button("Detect") {
              if let detected = service.suggestedToolPath(rootHint: rootPath) {
                toolPath = detected
                lastDetectedToolPath = detected
              }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.translationValidator.detect")
          }
        }

        Toggle("Summary only", isOn: $showSummaryOnly)
          .accessibilityIdentifier("agents.translationValidator.summaryOnly")

        Toggle("Use Apple on-device AI for suspects", isOn: $useAppleAI)
          .disabled(!service.appleAIAvailable)
          .accessibilityIdentifier("agents.translationValidator.useAppleAI")

        if useAppleAI && !service.appleAIAvailable {
          Text("Apple AI is not available on this device.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Toggle("Redact samples before AI", isOn: $redactSamples)
          .disabled(!useAppleAI)
          .accessibilityIdentifier("agents.translationValidator.redactSamples")

        if useAppleAI && !redactSamples {
          Text("Raw samples will be sent to the on-device model.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("Filters")
            .font(.caption)
            .foregroundStyle(.secondary)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 8) {
            Toggle("Missing", isOn: $filterMissing)
              .accessibilityIdentifier("agents.translationValidator.filter.missing")
            Toggle("Extra", isOn: $filterExtra)
              .accessibilityIdentifier("agents.translationValidator.filter.extra")
            Toggle("Placeholders", isOn: $filterPlaceholders)
              .accessibilityIdentifier("agents.translationValidator.filter.placeholders")
            Toggle("Types", isOn: $filterTypes)
              .accessibilityIdentifier("agents.translationValidator.filter.types")
            Toggle("Suspects", isOn: $filterSuspects)
              .accessibilityIdentifier("agents.translationValidator.filter.suspects")
          }
          .toggleStyle(.switch)
        }

        HStack(spacing: 12) {
          Button(service.isRunning ? "Running..." : "Run Validator") {
            let options = TranslationValidatorService.Options(
              root: rootPath,
              translationsPath: translationsPath.isEmpty ? nil : translationsPath,
              baseLocale: baseLocale.isEmpty ? nil : baseLocale,
              only: selectedOnly,
              summary: showSummaryOnly,
              toolPath: toolPath.isEmpty ? nil : toolPath,
              useAppleAI: useAppleAI,
              redactSamples: redactSamples
            )
            if isRiskyRoot(rootPath) {
              pendingOptions = options
              showingRootConfirm = true
            } else {
              Task { await service.validate(options: options) }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(service.isRunning || rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("agents.translationValidator.run")

          Button("Stop") {
            service.cancel()
          }
          .buttonStyle(.bordered)
          .disabled(!service.isRunning)
          .accessibilityIdentifier("agents.translationValidator.stop")
        }

        if let detected = lastDetectedToolPath {
          Text("Detected tool: \(detected)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Set a project root to avoid scanning the whole disk.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let error = service.lastError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      if let report = service.lastReport {
        ToolSection("Suggestions") {
          if let summary = service.lastSummary {
            ForEach(summary.roots, id: \.path) { root in
              VStack(alignment: .leading, spacing: 8) {
                Text(root.path)
                  .font(.subheadline)
                HStack(spacing: 12) {
                  summaryPill("Files", root.files)
                  if filterMissing { summaryPill("Missing", root.missingKeys) }
                  if filterExtra { summaryPill("Extra", root.extraKeys) }
                  if filterTypes { summaryPill("Types", root.typeMismatches) }
                  if filterPlaceholders { summaryPill("Placeholders", root.placeholderMismatches) }
                  if filterSuspects { summaryPill("Suspects", root.suspectTranslations) }
                }
              }
              .padding(.vertical, 6)
            }
          }

          if !showSummaryOnly {
            ForEach(report.roots, id: \.path) { root in
              VStack(alignment: .leading, spacing: 10) {
                Text("\(root.path)")
                  .font(.subheadline)

                ForEach(root.files, id: \.file) { file in
                  if fileHasVisibleIssues(file) {
                    DisclosureGroup(file.file) {
                      VStack(alignment: .leading, spacing: 6) {
                        if filterMissing {
                          KeyListView(title: "Missing", entries: file.missingKeys)
                        }
                        if filterExtra {
                          KeyListView(title: "Extra", entries: file.extraKeys)
                        }
                        if filterTypes {
                          ForEach(file.typeMismatches.indices, id: \.self) { index in
                            let mismatch = file.typeMismatches[index]
                            let text = "Type mismatch [\(mismatch.locale)] \(mismatch.key): \(mismatch.expected.rawValue) → \(mismatch.found.rawValue)"
                            Text(verbatim: text)
                              .font(.caption)
                              .foregroundStyle(.secondary)
                          }
                        }
                        if filterPlaceholders {
                          ForEach(file.placeholderMismatches.indices, id: \.self) { index in
                            let mismatch = file.placeholderMismatches[index]
                            let text = "Placeholder mismatch [\(mismatch.locale)] \(mismatch.key): \(String(describing: mismatch.expected)) → \(String(describing: mismatch.found))"
                            Text(verbatim: text)
                              .font(.caption)
                              .foregroundStyle(.secondary)
                          }
                        }
                        if filterSuspects {
                          VStack(alignment: .leading, spacing: 8) {
                            ForEach(file.suspectTranslations.indices, id: \.self) { index in
                              let suspect = file.suspectTranslations[index]
                              VStack(alignment: .leading, spacing: 4) {
                                Text("Suspect [\(suspect.locale)] \(suspect.key)")
                                  .font(.caption)
                                  .fontWeight(.semibold)
                                Text(suspect.reason)
                                  .font(.caption)
                                  .foregroundStyle(.secondary)
                                if let baseSample = suspect.baseSample,
                                   let localeSample = suspect.localeSample {
                                  VStack(alignment: .leading, spacing: 2) {
                                    Text("English: \(baseSample)")
                                      .font(.caption2)
                                      .foregroundStyle(.secondary)
                                    Text("Locale: \(localeSample)")
                                      .font(.caption2)
                                      .foregroundStyle(.secondary)
                                  }
                                  .padding(.leading, 6)
                                }
                              }
                              .padding(.vertical, 4)
                            }
                          }
                        }
                      }
                      .padding(.vertical, 4)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    .alert("Large scan warning", isPresented: $showingRootConfirm) {
      Button("Cancel", role: .cancel) {
        pendingOptions = nil
      }
      .accessibilityIdentifier("agents.translationValidator.confirm.cancel")
      Button("Run Anyway", role: .destructive) {
        if let options = pendingOptions {
          Task { await service.validate(options: options) }
        }
        pendingOptions = nil
      }
      .accessibilityIdentifier("agents.translationValidator.confirm.run")
    } message: {
      Text("The selected root looks broad and may scan a large portion of your disk. Continue?")
    }
  }

  private func summaryPill(_ label: String, _ value: Int) -> some View {
    Chip(
      text: "\(label): \(value)",
      background: Color.blue.opacity(0.12),
      horizontalPadding: 8,
      verticalPadding: 4
    )
  }

  private func fileHasVisibleIssues(_ file: FileReport) -> Bool {
    if filterMissing && !file.missingKeys.isEmpty { return true }
    if filterExtra && !file.extraKeys.isEmpty { return true }
    if filterTypes && !file.typeMismatches.isEmpty { return true }
    if filterPlaceholders && !file.placeholderMismatches.isEmpty { return true }
    if filterSuspects && !file.suspectTranslations.isEmpty { return true }
    return false
  }

  private func isRiskyRoot(_ path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    let expanded = expandPath(trimmed)
    let risky: Set<String> = [
      "/",
      FileManager.default.homeDirectoryForCurrentUser.path,
      "/Users",
      "/System",
      "/Library",
      "/Applications"
    ]
    return risky.contains(expanded)
  }

  private func expandPath(_ path: String) -> String {
    if path.hasPrefix("~") {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return path.replacingOccurrences(of: "~", with: home)
    }
    return path
  }
}

private struct KeyListView: View {
  let title: String
  let entries: [LocaleKeyList]

  private let maxItems = 12

  var body: some View {
    ForEach(entries.indices, id: \.self) { index in
      let entry = entries[index]
      let keys = entry.keys
      let preview = keys.prefix(maxItems).joined(separator: ", ")
      let remaining = keys.count - min(keys.count, maxItems)
      let suffix = remaining > 0 ? " (+\(remaining) more)" : ""
      Text("\(title) (\(entry.locale)): \(preview)\(suffix)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
