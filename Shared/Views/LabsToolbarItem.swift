//
//  LabsToolbarItem.swift
//  Peel
//
//  Toolbar item that surfaces enabled experimental features.
//  When any lab feature is toggled on in Settings > Labs, a beaker icon
//  appears in the toolbar with a menu of available experiments.
//

import SwiftUI

// MARK: - Lab Feature Catalog

/// Describes an experimental feature that can be toggled on/off in Settings.
struct LabFeature: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let systemImage: String
  let storageKey: String

  /// All known lab features. Order matches the Settings > Labs UI.
  static let all: [LabFeature] = [
    LabFeature(
      id: "brew",
      title: "Homebrew",
      subtitle: "Manage Homebrew packages and casks",
      systemImage: "mug",
      storageKey: "feature.showBrew"
    ),
    LabFeature(
      id: "pii",
      title: "PII Scrubber",
      subtitle: "Detect and redact personally identifiable information",
      systemImage: "eye.slash",
      storageKey: "feature.showPIIScrubber"
    ),
    LabFeature(
      id: "docling",
      title: "Docling Import",
      subtitle: "Convert documents to markdown via Docling",
      systemImage: "doc.richtext",
      storageKey: "feature.showDoclingImport"
    ),
    LabFeature(
      id: "translation",
      title: "Translation Validation",
      subtitle: "Validate .strings localization files for correctness",
      systemImage: "globe",
      storageKey: "feature.showTranslationValidation"
    ),
    LabFeature(
      id: "vm",
      title: "VM Isolation",
      subtitle: "Run agent tasks inside sandboxed virtual machines",
      systemImage: "desktopcomputer",
      storageKey: "feature.showVMIsolation"
    ),
    LabFeature(
      id: "modelLab",
      title: "Model Lab",
      subtitle: "Browse and try out MLX models locally",
      systemImage: "cpu",
      storageKey: "feature.showModelLab"
    ),
  ]
}

// MARK: - Toolbar Item

/// Shows a beaker icon in the toolbar when any lab feature is enabled.
/// Clicking reveals a menu to open each enabled feature as a sheet.
struct LabsToolbarItem: ToolbarContent {
  @AppStorage("feature.showBrew") private var showBrew = false
  @AppStorage("feature.showPIIScrubber") private var showPIIScrubber = false
  @AppStorage("feature.showDoclingImport") private var showDoclingImport = false
  @AppStorage("feature.showTranslationValidation") private var showTranslationValidation = false
  @AppStorage("feature.showVMIsolation") private var showVMIsolation = false
  @AppStorage("feature.showModelLab") private var showModelLab = false

  @Binding var activeLabFeature: LabFeature?

  private var enabledFeatures: [LabFeature] {
    LabFeature.all.filter { isEnabled($0) }
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      if !enabledFeatures.isEmpty {
        Menu {
          ForEach(enabledFeatures) { feature in
            Button {
              activeLabFeature = feature
            } label: {
              Label(feature.title, systemImage: feature.systemImage)
            }
          }
          Divider()
          SettingsLink {
            Label("Labs Settings…", systemImage: "gear")
          }
        } label: {
          Label("Labs", systemImage: "flask")
        }
        .help("Experimental features")
      }
    }
  }

  private func isEnabled(_ feature: LabFeature) -> Bool {
    switch feature.id {
    case "brew": return showBrew
    case "pii": return showPIIScrubber
    case "docling": return showDoclingImport
    case "translation": return showTranslationValidation
    case "vm": return showVMIsolation
    case "modelLab": return showModelLab
    default: return false
    }
  }
}

// MARK: - Lab Feature Sheet Content

/// Routes a `LabFeature` to its corresponding view inside a sheet.
struct LabFeatureSheetContent: View {
  let feature: LabFeature
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      featureView
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    .frame(minWidth: 600, minHeight: 400)
  }

  @ViewBuilder
  private var featureView: some View {
    switch feature.id {
    case "brew":
      Brew_RootView()
    case "pii":
      PIIScrubberView()
    case "docling":
      DoclingImportView(mcpServer: mcpServer)
    case "translation":
      TranslationValidationView()
    case "vm":
      VMIsolationDashboardView()
    case "modelLab":
      ModelLabView()
    default:
      Text("Unknown feature")
    }
  }
}

// MARK: - Settings Toggle Row

/// A richer toggle row for the Settings > Labs tab showing title, description, and icon.
struct LabsToggleRow: View {
  let feature: LabFeature
  @Binding var isOn: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: feature.systemImage)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .fontWeight(.medium)
        Text(feature.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Toggle("", isOn: $isOn)
        .labelsHidden()
    }
    .padding(.vertical, 2)
  }
}
