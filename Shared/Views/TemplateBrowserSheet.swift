//
//  TemplateBrowserSheet.swift
//  Peel
//
//  A browsable gallery of chain templates grouped by category.
//  Users can pick a template to kick off a new agent chain run.
//

import SwiftUI

// MARK: - Template Browser Sheet

struct TemplateBrowserSheet: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(\.dismiss) private var dismiss

  @State private var selectedCategory: TemplateCategory = .core
  @State private var searchText = ""
  @State private var selectedTemplate: ChainTemplate?
  @State private var promptText = ""
  @State private var isRunning = false
  @State private var errorMessage: String?

  private var agentManager: AgentManager { mcpServer.agentManager }

  private var allTemplates: [ChainTemplate] { agentManager.allTemplates }

  private var filteredTemplates: [ChainTemplate] {
    let byCategory = allTemplates.filter { $0.category == selectedCategory }
    if searchText.isEmpty { return byCategory }
    return byCategory.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || $0.description.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Category picker
        categoryPicker
          .padding(.horizontal, 16)
          .padding(.top, 8)

        Divider()
          .padding(.top, 8)

        // Template list
        if filteredTemplates.isEmpty {
          ContentUnavailableView {
            Label("No Templates", systemImage: "doc.text.magnifyingglass")
          } description: {
            Text("No templates match your search in this category.")
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(filteredTemplates) { template in
                TemplateCard(
                  template: template,
                  isSelected: selectedTemplate?.id == template.id
                )
                .contentShape(Rectangle())
                .onTapGesture {
                  withAnimation(.snappy(duration: 0.2)) {
                    selectedTemplate = template
                  }
                }
              }
            }
            .padding(16)
          }
        }

        Divider()

        // Run panel
        runPanel
          .padding(16)
      }
      .searchable(text: $searchText, placement: .toolbar, prompt: "Search templates…")
      .navigationTitle("Run New Task")
      #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      #endif
    }
    #if os(macOS)
    .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 600)
    #endif
  }

  // MARK: - Category Picker

  private var categoryPicker: some View {
    HStack(spacing: 12) {
      ForEach(TemplateCategory.allCases, id: \.self) { category in
        let count = allTemplates.filter { $0.category == category }.count
        Button {
          withAnimation(.snappy(duration: 0.2)) {
            selectedCategory = category
            selectedTemplate = nil
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: category.iconName)
            Text(category.displayName)
            Text("(\(count))")
              .foregroundStyle(.tertiary)
          }
          .font(.caption)
          .fontWeight(selectedCategory == category ? .semibold : .regular)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            selectedCategory == category
              ? Color.accentColor.opacity(0.15)
              : Color.clear,
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
  }

  // MARK: - Run Panel

  @ViewBuilder
  private var runPanel: some View {
    VStack(spacing: 12) {
      if let template = selectedTemplate {
        HStack(spacing: 8) {
          Image(systemName: template.category.iconName)
            .foregroundStyle(.secondary)
          Text(template.name)
            .fontWeight(.medium)
          Spacer()
          Text("\(template.steps.count) step\(template.steps.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          TextField("What should the agent do?", text: $promptText, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
            .onSubmit { runSelectedTemplate() }

          Button {
            runSelectedTemplate()
          } label: {
            if isRunning {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Run", systemImage: "play.fill")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        }
      } else {
        HStack {
          Image(systemName: "hand.point.up")
            .foregroundStyle(.secondary)
          Text("Select a template above to get started")
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
      }
    }
  }

  // MARK: - Actions

  private func runSelectedTemplate() {
    guard let template = selectedTemplate else { return }
    let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }

    isRunning = true
    errorMessage = nil

    Task {
      let arguments: [String: Any] = [
        "prompt": prompt,
        "templateId": template.id.uuidString,
        "returnImmediately": true,
      ]
      let (status, _) = await mcpServer.handleChainRun(id: nil, arguments: arguments)
      if status == 200 {
        dismiss()
      } else {
        errorMessage = "Failed to start chain (status \(status))"
        isRunning = false
      }
    }
  }
}

// MARK: - Template Card

private struct TemplateCard: View {
  let template: ChainTemplate
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: iconForTemplate)
          .font(.title3)
          .foregroundStyle(isSelected ? .white : .accentColor)
          .frame(width: 32, height: 32)
          .background(
            isSelected
              ? Color.accentColor
              : Color.accentColor.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8)
          )

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(template.name)
              .fontWeight(.semibold)

            if template.isBuiltIn {
              Text("Built-in")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
          }

          Text(template.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        Spacer()

        // Step count badge
        VStack(spacing: 2) {
          Text("\(template.steps.count)")
            .font(.title3.monospacedDigit())
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
          Text(template.steps.count == 1 ? "step" : "steps")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      // Step pills
      if !template.steps.isEmpty {
        HStack(spacing: 4) {
          ForEach(Array(template.steps.prefix(6).enumerated()), id: \.offset) { _, step in
            Text(step.name)
              .font(.caption2)
              .lineLimit(1)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(pillColor(for: step), in: Capsule())
          }
          if template.steps.count > 6 {
            Text("+\(template.steps.count - 6)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      // Execution environment badge
      if template.executionEnvironment != .host {
        HStack(spacing: 4) {
          Image(systemName: "desktopcomputer")
            .font(.caption2)
          Text(template.executionEnvironment.rawValue.uppercased())
            .font(.caption2)
            .fontWeight(.medium)
          Text("· \(template.toolchain.displayName)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.orange)
      }
    }
    .padding(12)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.08)
        : Color.clear,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          isSelected ? Color.accentColor : Color.separator.opacity(0.5),
          lineWidth: isSelected ? 2 : 1
        )
    )
  }

  private var iconForTemplate: String {
    switch template.category {
    case .core: return "bolt.fill"
    case .specialized: return "slider.horizontal.3"
    case .yolo: return "shield.checkmark.fill"
    }
  }

  private func pillColor(for step: AgentStepTemplate) -> Color {
    switch step.role {
    case .planner: return .blue.opacity(0.15)
    case .implementer: return .green.opacity(0.15)
    case .reviewer: return .orange.opacity(0.15)
    }
  }
}

// MARK: - Color.separator helper

private extension Color {
  static var separator: Color {
    #if os(macOS)
    Color(nsColor: .separatorColor)
    #else
    Color(uiColor: .separator)
    #endif
  }
}
