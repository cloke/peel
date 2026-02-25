//
//  DoclingPolicyScopeView.swift
//  Peel
//

import SwiftUI

#if os(macOS)
import SwiftData

struct DoclingPolicyScopeView: View {
  let companies: [PolicyCompany]
  let presets: [PolicyPreset]
  @Binding var selectedCompanyId: UUID?
  @Binding var selectedPresetId: UUID?
  @Environment(\.modelContext) private var modelContext

  @State private var newCompanyName = ""
  @State private var newPresetName = ""
  @State private var newPresetProfile = "high"
  @State private var newPresetImagesScale: Double = 2.0
  @State private var newPresetOCR = true
  @State private var newPresetTables = true
  @State private var newPresetCode = true
  @State private var newPresetFormula = true

  var body: some View {
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

  private func slugify(_ input: String) -> String {
    let lower = input.lowercased()
    let allowed = lower.map { char -> String in
      if char.isLetter || char.isNumber { return String(char) }
      return "-"
    }.joined()
    let collapsed = allowed.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}
#endif
