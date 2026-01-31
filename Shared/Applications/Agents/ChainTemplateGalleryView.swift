//
//  ChainTemplateGalleryView.swift
//  KitchenSync
//
//  Created on 1/21/26.
//

import MCPCore
import PeelUI
import SwiftUI

struct ChainTemplateGalleryView: View {
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @State private var templateToDelete: ChainTemplate?
  @State private var showResetConfirmation = false
  @State private var showingUnavailableAlert = false
  @State private var unavailableTemplate: ChainTemplate?

  private var coreTemplates: [ChainTemplate] {
    agentManager.allTemplates.filter { $0.isBuiltIn && $0.category == .core }
  }

  private var specializedTemplates: [ChainTemplate] {
    agentManager.allTemplates.filter { $0.isBuiltIn && $0.category == .specialized }
  }

  private var savedTemplates: [ChainTemplate] {
    agentManager.allTemplates.filter { !$0.isBuiltIn }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        providerStatusHeader

        if agentManager.allTemplates.isEmpty {
          ContentUnavailableView {
            Label("No Templates", systemImage: "square.grid.2x2")
          } description: {
            Text("Create a chain and save it as a template to get started.")
          }
        } else {
          if !coreTemplates.isEmpty {
            templateSection(title: "Core Templates", templates: coreTemplates)
          }

          if !specializedTemplates.isEmpty {
            templateSection(title: "Specialized Templates", templates: specializedTemplates)
          }

          if !savedTemplates.isEmpty {
            templateSection(title: "Saved Templates", templates: savedTemplates)
          }
        }
      }
      .padding(20)
    }
    .navigationTitle("Template Gallery")
    .confirmDialog(
      "Delete Template",
      isPresented: Binding(
        get: { templateToDelete != nil },
        set: { isPresented in
          if !isPresented { templateToDelete = nil }
        }
      ),
      confirmLabel: "Delete",
      confirmRole: .destructive,
      message: "This cannot be undone."
    ) {
      if let templateToDelete {
        agentManager.deleteTemplate(templateToDelete)
      }
      templateToDelete = nil
    }
    .confirmDialog(
      "Reset Templates",
      isPresented: $showResetConfirmation,
      confirmLabel: "Reset",
      confirmRole: .destructive,
      message: "This will delete all saved templates. Built-in templates will remain."
    ) {
      agentManager.resetTemplatesToDefaults()
    }
    .alert("Provider Unavailable", isPresented: $showingUnavailableAlert) {
      Button("OK", role: .cancel) { }
    } message: {
      if let template = unavailableTemplate {
        unavailableMessage(for: template)
      }
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 6) {
        Text("Chain Templates")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Create new chains quickly with a template. Built-in templates are read-only.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      if !savedTemplates.isEmpty {
        Button("Reset to Defaults") {
          showResetConfirmation = true
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private var providerStatusHeader: some View {
    HStack(spacing: 16) {
      providerStatus(
        name: "GitHub Copilot",
        available: cliService.copilotStatus.isAvailable,
        icon: "terminal"
      )
      providerStatus(
        name: "Claude CLI",
        available: cliService.claudeStatus.isAvailable,
        icon: "sparkles"
      )
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func providerStatus(name: String, available: Bool, icon: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .foregroundStyle(available ? .green : .orange)
      Text(name)
        .font(.caption)
      Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(available ? .green : .orange)
        .imageScale(.small)
    }
  }

  private func unavailableMessage(for template: ChainTemplate) -> Text {
    let unavailableModels = template.unavailableModels(
      copilotAvailable: cliService.copilotStatus.isAvailable,
      claudeAvailable: cliService.claudeStatus.isAvailable
    )
    
    let providers = Set(unavailableModels.map(\.requiredProvider))
    var message = "This template requires:\n\n"
    
    for provider in providers {
      switch provider {
      case .copilot:
        message += "• GitHub Copilot: Run 'gh copilot' in terminal\n"
      case .claude:
        message += "• Claude CLI: Run 'claude auth login' in terminal\n"
      }
    }
    
    return Text(message)
  }

  private func templateSection(title: String, templates: [ChainTemplate]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
        ForEach(templates) { template in
          TemplateCard(
            template: template,
            cliService: cliService,
            onCreate: { createChain(from: template) },
            onDelete: template.isBuiltIn ? nil : { templateToDelete = template }
          )
        }
      }
    }
  }

  private func createChain(from template: ChainTemplate) {
    let isAvailable = template.isFullyAvailable(
      copilotAvailable: cliService.copilotStatus.isAvailable,
      claudeAvailable: cliService.claudeStatus.isAvailable
    )
    
    if !isAvailable {
      unavailableTemplate = template
      showingUnavailableAlert = true
      return
    }
    
    let chain = agentManager.createChainFromTemplate(template, workingDirectory: agentManager.lastUsedWorkingDirectory)
    agentManager.selectedAgent = nil
    agentManager.selectedChain = chain
  }
}

private struct TemplateCard: View {
  let template: ChainTemplate
  let cliService: CLIService
  let onCreate: () -> Void
  let onDelete: (() -> Void)?
  
  private var costTier: (label: String, color: Color) {
    let cost = template.estimatedTotalCost
    if cost == 0 {
      return ("Free", .green)
    } else if cost <= 2.0 {
      return ("Standard", .blue)
    } else {
      return ("Premium", .orange)
    }
  }

  private var isAvailable: Bool {
    template.isFullyAvailable(
      copilotAvailable: cliService.copilotStatus.isAvailable,
      claudeAvailable: cliService.claudeStatus.isAvailable
    )
  }

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
        if !isAvailable {
          Chip(text: "Unavailable", systemImage: "exclamationmark.triangle.fill", foreground: .orange, background: Color.orange.opacity(0.15))
        } else if template.isBuiltIn {
          Chip(text: "Built-in", systemImage: "lock.fill", foreground: .blue, background: Color.blue.opacity(0.15))
        } else {
          Chip(text: "Saved", systemImage: "star.fill", foreground: .orange, background: Color.orange.opacity(0.15))
        }
        costTierChip(for: template.costTier)
      }

      HStack(spacing: 8) {
        Chip(text: "\(template.steps.count) steps", systemImage: "list.number", foreground: .secondary)
        Chip(text: template.costDisplay, systemImage: "creditcard", foreground: .secondary)
        Chip(text: costTier.label, systemImage: "dollarsign.circle.fill", foreground: costTier.color, background: costTier.color.opacity(0.15))
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
        .accessibilityIdentifier("agents.templateGallery.template.\(template.id.uuidString).create")

        Spacer()

        if let onDelete {
          DestructiveActionButton {
            onDelete()
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.templateGallery.template.\(template.id.uuidString).delete")
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

  @ViewBuilder
  private func costTierChip(for tier: MCPCopilotModel.CostTier) -> some View {
    switch tier {
    case .free:
      Chip(text: tier.displayName, systemImage: tier.icon, foreground: .green, background: Color.green.opacity(0.15))
    case .low:
      Chip(text: tier.displayName, systemImage: tier.icon, foreground: .blue, background: Color.blue.opacity(0.15))
    case .standard:
      Chip(text: tier.displayName, systemImage: tier.icon, foreground: .orange, background: Color.orange.opacity(0.15))
    case .premium:
      Chip(text: tier.displayName, systemImage: tier.icon, foreground: .red, background: Color.red.opacity(0.15))
    }
  }
}
