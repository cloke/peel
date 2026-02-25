//
//  DoclingRulesView.swift
//  Peel
//

import SwiftUI

#if os(macOS)
import SwiftData

struct DoclingRulesView: View {
  let selectedCompanyId: UUID?
  let rules: [PolicyRule]
  @Environment(\.modelContext) private var modelContext

  @State private var newRuleName = ""
  @State private var newRulePattern = ""
  @State private var newRuleSeverity = "warning"

  private var rulesForSelectedCompany: [PolicyRule] {
    guard let selectedCompanyId else { return [] }
    return rules.filter { $0.companyId == selectedCompanyId && $0.isEnabled }
  }

  var body: some View {
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
}
#endif
