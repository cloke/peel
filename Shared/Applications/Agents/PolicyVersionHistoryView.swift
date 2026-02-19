//
//  PolicyVersionHistoryView.swift
//  Peel
//

import SwiftUI

#if os(macOS)
import SwiftData

struct PolicyVersionHistoryView: View {
  let company: PolicyCompany
  @Binding var compareDocA: PolicyDocument?
  @Binding var compareDocB: PolicyDocument?
  @Binding var showDiff: Bool

  @Environment(\.modelContext) private var modelContext
  @Query private var allDocuments: [PolicyDocument]

  @State private var selectedForCompare: Set<UUID> = []

  init(
    company: PolicyCompany,
    compareDocA: Binding<PolicyDocument?>,
    compareDocB: Binding<PolicyDocument?>,
    showDiff: Binding<Bool>
  ) {
    self.company = company
    self._compareDocA = compareDocA
    self._compareDocB = compareDocB
    self._showDiff = showDiff
    let companyId = company.id
    self._allDocuments = Query(
      filter: #Predicate<PolicyDocument> { $0.companyId == companyId },
      sort: \PolicyDocument.importedAt,
      order: .reverse
    )
  }

  private var baseline: PolicyDocument? {
    allDocuments.first { $0.isBaseline }
  }

  private var latest: PolicyDocument? {
    allDocuments.first
  }

  private var hasDrift: Bool {
    guard let baseline, let latest, baseline.id != latest.id else { return false }
    return baseline.violationCount != latest.violationCount
  }

  var body: some View {
    VStack(spacing: 0) {
      if hasDrift {
        Label("Drift detected: current version differs from baseline", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.orange.opacity(0.1))
      }

      List(allDocuments) { doc in
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Text(doc.title.isEmpty ? "Untitled" : doc.title)
                .fontWeight(.medium)
              if doc.isBaseline {
                Text("Baseline")
                  .font(.caption2)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(.green.opacity(0.15))
                  .foregroundStyle(.green)
                  .clipShape(RoundedRectangle(cornerRadius: 4))
              }
            }
            Text(doc.importedAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(spacing: 8) {
              Text("Profile: \(doc.profile)")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text("\(doc.wordCount) words")
                .font(.caption2)
                .foregroundStyle(.secondary)
              if doc.violationCount > 0 {
                Text("\(doc.violationCount) violations")
                  .font(.caption2)
                  .foregroundStyle(.red)
              }
            }
          }

          Spacer()

          Toggle(isOn: Binding(
            get: { selectedForCompare.contains(doc.id) },
            set: { checked in
              if checked {
                selectedForCompare.insert(doc.id)
              } else {
                selectedForCompare.remove(doc.id)
              }
            }
          )) {
            Text("Compare")
              .font(.caption)
          }
          .toggleStyle(.checkbox)

          Button("Set Baseline") {
            setBaseline(doc)
          }
          .buttonStyle(.bordered)
          .font(.caption)
          .disabled(doc.isBaseline)
        }
        .padding(.vertical, 4)
      }

      HStack {
        Spacer()
        Button("Compare Selected") {
          let docs = allDocuments.filter { selectedForCompare.contains($0.id) }
          guard docs.count == 2 else { return }
          compareDocA = docs[0]
          compareDocB = docs[1]
          showDiff = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedForCompare.count != 2)
        .padding()
      }
    }
    .frame(minWidth: 600, minHeight: 400)
    .navigationTitle("Version History — \(company.name)")
  }

  private func setBaseline(_ doc: PolicyDocument) {
    for d in allDocuments {
      d.isBaseline = (d.id == doc.id)
    }
    try? modelContext.save()
  }
}
#endif
