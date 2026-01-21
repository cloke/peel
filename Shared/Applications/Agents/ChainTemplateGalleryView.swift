//
//  ChainTemplateGalleryView.swift
//  KitchenSync
//
//  Created on 1/21/26.
//

import SwiftUI

struct ChainTemplateGalleryView: View {
  @Bindable var agentManager: AgentManager
  @State private var templateToDelete: ChainTemplate?

  private var builtInTemplates: [ChainTemplate] {
    agentManager.allTemplates.filter { $0.isBuiltIn }
  }

  private var savedTemplates: [ChainTemplate] {
    agentManager.allTemplates.filter { !$0.isBuiltIn }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header

        if agentManager.allTemplates.isEmpty {
          ContentUnavailableView {
            Label("No Templates", systemImage: "square.grid.2x2")
          } description: {
            Text("Create a chain and save it as a template to get started.")
          }
        } else {
          if !builtInTemplates.isEmpty {
            templateSection(title: "Built-in Templates", templates: builtInTemplates)
          }

          if !savedTemplates.isEmpty {
            templateSection(title: "Saved Templates", templates: savedTemplates)
          }
        }
      }
      .padding(20)
    }
    .navigationTitle("Template Gallery")
    .confirmationDialog(
      "Delete Template",
      isPresented: Binding(
        get: { templateToDelete != nil },
        set: { isPresented in
          if !isPresented { templateToDelete = nil }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let templateToDelete {
          agentManager.deleteTemplate(templateToDelete)
        }
        templateToDelete = nil
      }
      Button("Cancel", role: .cancel) {
        templateToDelete = nil
      }
    } message: {
      Text("This cannot be undone.")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Chain Templates")
        .font(.title2)
        .fontWeight(.semibold)
      Text("Create new chains quickly with a template. Built-in templates are read-only.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func templateSection(title: String, templates: [ChainTemplate]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
        ForEach(templates) { template in
          TemplateCard(
            template: template,
            onCreate: { createChain(from: template) },
            onDelete: template.isBuiltIn ? nil : { templateToDelete = template }
          )
        }
      }
    }
  }

  private func createChain(from template: ChainTemplate) {
    let chain = agentManager.createChainFromTemplate(template, workingDirectory: agentManager.lastUsedWorkingDirectory)
    agentManager.selectedAgent = nil
    agentManager.selectedChain = chain
  }
}

private struct TemplateCard: View {
  let template: ChainTemplate
  let onCreate: () -> Void
  let onDelete: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(template.name)
            .font(.headline)
          if !template.description.isEmpty {
            Text(template.description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
        }
        Spacer()
        if template.isBuiltIn {
          Chip(text: "Built-in", systemImage: "lock.fill", foreground: .blue, background: Color.blue.opacity(0.15))
        } else {
          Chip(text: "Saved", systemImage: "star.fill", foreground: .orange, background: Color.orange.opacity(0.15))
        }
      }

      HStack(spacing: 8) {
        Chip(text: "\(template.steps.count) steps", systemImage: "list.number", foreground: .secondary)
        Chip(text: template.costDisplay, systemImage: "creditcard", foreground: .secondary)
        if let validationLabel = template.validationSummaryLabel {
          Chip(text: validationLabel, systemImage: "checkmark.seal", foreground: .secondary)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(template.steps.enumerated()), id: \.element.id) { index, step in
          HStack(spacing: 8) {
            Text("\(index + 1).")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Image(systemName: step.role.iconName)
              .foregroundStyle(roleColor(step.role))
            Text(step.name)
              .font(.caption)
            Spacer()
            Text(step.model.shortName)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      HStack {
        Button("Create Chain") {
          onCreate()
        }
        .buttonStyle(.borderedProminent)

        Spacer()

        if let onDelete {
          Button(role: .destructive) {
            onDelete()
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding(14)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
    )
  }

  private func roleColor(_ role: AgentRole) -> Color {
    switch role {
    case .planner:
      return .blue
    case .implementer:
      return .green
    case .reviewer:
      return .purple
    }
  }
}
