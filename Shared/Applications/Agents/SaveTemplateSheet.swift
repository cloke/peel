//
//  SaveTemplateSheet.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

struct SaveTemplateSheet: View {
  let chain: AgentChain
  @Bindable var agentManager: AgentManager
  @Environment(\.dismiss) private var dismiss

  @State private var templateName = ""
  @State private var templateDescription = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Template Name", text: $templateName, prompt: Text(chain.name))
          TextField("Description (optional)", text: $templateDescription, axis: .vertical)
            .lineLimit(2...4)
        }

        Section("Agents in Template") {
          ForEach(Array(chain.agents.enumerated()), id: \.element.id) { index, agent in
            HStack {
              Text("\(index + 1).")
                .foregroundStyle(.secondary)
              Image(systemName: agent.role.iconName)
                .foregroundStyle(roleColor(agent.role))
              VStack(alignment: .leading) {
                Text(agent.name)
                  .font(.subheadline)
                Text(agent.model.shortName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(agent.role.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Section {
          Text("This template can be reused to quickly create new chains with the same agent configuration.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Save as Template")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            let name = templateName.isEmpty ? chain.name : templateName
            agentManager.saveChainAsTemplate(chain, name: name, description: templateDescription)
            dismiss()
          }
        }
      }
      .frame(minWidth: 400, minHeight: 350)
    }
  }

  private func roleColor(_ role: AgentRole) -> Color {
    switch role {
    case .planner: return .blue
    case .implementer: return .green
    case .reviewer: return .orange
    }
  }
}
