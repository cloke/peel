//
//  CommandPaletteView.swift
//  Peel
//
//  Cmd+K global search overlay. Provides quick access to RAG search
//  across all indexed repositories, plus action shortcuts for navigation
//  and experimental features.
//

import SwiftUI

// MARK: - Command Action

/// A quick-action item surfaced in the Cmd+K palette alongside RAG results.
struct CommandAction: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let systemImage: String
  let keywords: [String]
  let action: () -> Void

  /// Returns true if the query matches this action's title or keywords.
  func matches(_ query: String) -> Bool {
    let q = query.lowercased()
    if q.isEmpty { return true }
    if title.lowercased().contains(q) { return true }
    if subtitle.lowercased().contains(q) { return true }
    return keywords.contains { $0.lowercased().contains(q) }
  }
}

struct CommandPaletteView: View {
  @Binding var isPresented: Bool
  @Environment(MCPServerService.self) private var mcpServer

  @AppStorage("feature.showBrew") private var showBrew = false
  @AppStorage("feature.showPIIScrubber") private var showPIIScrubber = false
  @AppStorage("feature.showDoclingImport") private var showDoclingImport = false
  @AppStorage("feature.showTranslationValidation") private var showTranslationValidation = false
  @AppStorage("feature.showVMIsolation") private var showVMIsolation = false

  @State private var query = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var results: [LocalRAGSearchResult] = []
  @State private var isSearching = false
  @State private var errorMessage: String?
  @State private var activeLabFeature: LabFeature?
  @FocusState private var isSearchFocused: Bool

  /// Computed list of available actions based on enabled features.
  private var availableActions: [CommandAction] {
    var actions: [CommandAction] = [
      CommandAction(
        id: "nav.repos",
        title: "Go to Repositories",
        subtitle: "Switch to the Repositories tab",
        systemImage: "tray.full",
        keywords: ["repos", "repositories", "git", "github"],
        action: {
          NotificationCenter.default.post(name: .navigateToTool, object: CurrentTool.repositories)
          isPresented = false
        }
      ),
      CommandAction(
        id: "nav.activity",
        title: "Go to Activity",
        subtitle: "Switch to the Activity dashboard",
        systemImage: "bolt.fill",
        keywords: ["activity", "chains", "agents", "dashboard"],
        action: {
          NotificationCenter.default.post(name: .navigateToTool, object: CurrentTool.activity)
          isPresented = false
        }
      ),
      CommandAction(
        id: "action.settings",
        title: "Open Settings",
        subtitle: "App preferences and configuration",
        systemImage: "gear",
        keywords: ["settings", "preferences", "config"],
        action: {
          #if os(macOS)
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
          #endif
          isPresented = false
        }
      ),
    ]

    // Lab features — only shown when enabled
    if showBrew {
      actions.append(CommandAction(
        id: "lab.brew",
        title: "Open Homebrew",
        subtitle: "Manage Homebrew packages and casks",
        systemImage: "mug",
        keywords: ["brew", "homebrew", "package", "cask"],
        action: { activeLabFeature = LabFeature.all.first { $0.id == "brew" }  }
      ))
    }
    if showPIIScrubber {
      actions.append(CommandAction(
        id: "lab.pii",
        title: "Open PII Scrubber",
        subtitle: "Detect and redact personally identifiable information",
        systemImage: "eye.slash",
        keywords: ["pii", "scrub", "redact", "privacy", "sensitive"],
        action: { activeLabFeature = LabFeature.all.first { $0.id == "pii" } }
      ))
    }
    if showDoclingImport {
      actions.append(CommandAction(
        id: "lab.docling",
        title: "Open Docling Import",
        subtitle: "Convert documents to markdown",
        systemImage: "doc.richtext",
        keywords: ["docling", "import", "document", "markdown", "convert"],
        action: { activeLabFeature = LabFeature.all.first { $0.id == "docling" } }
      ))
    }
    if showTranslationValidation {
      actions.append(CommandAction(
        id: "lab.translation",
        title: "Open Translation Validation",
        subtitle: "Validate .strings localization files",
        systemImage: "globe",
        keywords: ["translation", "localization", "strings", "i18n", "validate"],
        action: { activeLabFeature = LabFeature.all.first { $0.id == "translation" } }
      ))
    }
    if showVMIsolation {
      actions.append(CommandAction(
        id: "lab.vm",
        title: "Open VM Isolation",
        subtitle: "Run agent tasks in sandboxed virtual machines",
        systemImage: "desktopcomputer",
        keywords: ["vm", "virtual", "machine", "isolation", "sandbox"],
        action: { activeLabFeature = LabFeature.all.first { $0.id == "vm" } }
      ))
    }

    return actions
  }

  /// Actions that match the current query.
  private var matchingActions: [CommandAction] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return availableActions.filter { $0.matches(trimmed) }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Search bar
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .font(.title3)
          .foregroundStyle(.secondary)

        TextField("Search code or type a command…", text: $query)
          .textFieldStyle(.plain)
          .font(.body)
          .focused($isSearchFocused)
          .onSubmit { Task { await runSearch() } }

        if isSearching {
          ProgressView()
            .controlSize(.small)
        }

        Picker("", selection: $searchMode) {
          Text("Vector").tag(MCPServerService.RAGSearchMode.vector)
          Text("Text").tag(MCPServerService.RAGSearchMode.text)
          Text("Hybrid").tag(MCPServerService.RAGSearchMode.hybrid)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)

        Button {
          isPresented = false
        } label: {
          Text("ESC")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
      }
      .padding(12)

      Divider()

      // Results & Actions
      ScrollView {
        LazyVStack(spacing: 2) {
          // Actions section
          let actions = matchingActions
          if !actions.isEmpty {
            if !results.isEmpty || !query.isEmpty {
              CommandSectionHeader(title: "Actions")
            }
            ForEach(actions) { action in
              CommandActionRow(action: action)
            }
          }

          // Search results section
          if !results.isEmpty {
            CommandSectionHeader(title: "Code Results")
            ForEach(Array(results.prefix(30).enumerated()), id: \.offset) { _, result in
              CommandPaletteResultRow(result: result)
            }
          }

          // Empty states
          if results.isEmpty && matchingActions.isEmpty && !query.isEmpty && !isSearching {
            VStack(spacing: 8) {
              Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
              Text("No results found")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
          }

          if let error = errorMessage {
            VStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
              Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
          }
        }
        .padding(8)
      }

      // Hint at bottom when empty
      if results.isEmpty && query.isEmpty && !isSearching && errorMessage == nil {
        VStack(spacing: 4) {
          Text("Search code across all indexed repositories")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text("Press Return to search · actions match as you type")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
      }
    }
    .frame(maxWidth: 660, maxHeight: 500)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    .onAppear { isSearchFocused = true }
    .onExitCommand { isPresented = false }
    .sheet(item: $activeLabFeature) { feature in
      LabFeatureSheetContent(feature: feature)
    }
  }

  private func runSearch() async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    isSearching = true
    errorMessage = nil

    do {
      results = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode,
        limit: 30
      )
    } catch {
      errorMessage = error.localizedDescription
    }

    isSearching = false
  }
}

// MARK: - Section Header

private struct CommandSectionHeader: View {
  let title: String

  var body: some View {
    HStack {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
    }
    .padding(.horizontal, 8)
    .padding(.top, 6)
    .padding(.bottom, 2)
  }
}

// MARK: - Action Row

private struct CommandActionRow: View {
  let action: CommandAction

  var body: some View {
    Button {
      action.action()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: action.systemImage)
          .font(.callout)
          .foregroundStyle(.blue)
          .frame(width: 20)

        VStack(alignment: .leading, spacing: 1) {
          Text(action.title)
            .font(.callout)
            .fontWeight(.medium)
          Text(action.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Image(systemName: "return")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
  }
}

// MARK: - Result Row

private struct CommandPaletteResultRow: View {
  let result: LocalRAGSearchResult

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: iconForType)
          .font(.caption)
          .foregroundStyle(.blue)
          .frame(width: 16)

        Text(displayPath)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.middle)

        if let name = result.constructName {
          Text(name)
            .font(.caption)
            .foregroundStyle(.purple)
        }

        Spacer()

        Text("L\(result.startLine)–\(result.endLine)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .monospacedDigit()

        if let score = result.score {
          Text(String(format: "%.0f%%", score * 100))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }

      Text(result.snippet.components(separatedBy: "\n").prefix(2).joined(separator: " "))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
    .contentShape(Rectangle())
  }

  private var displayPath: String {
    let path = result.filePath
    let components = path.split(separator: "/")
    if components.count > 2 {
      return components.suffix(2).joined(separator: "/")
    }
    return path
  }

  private var iconForType: String {
    switch result.constructType {
    case "class", "struct": return "c.square"
    case "function", "method": return "f.square"
    case "enum": return "e.square"
    case "protocol": return "p.square"
    case "extension": return "curlybraces"
    default: return "doc.text"
    }
  }
}
