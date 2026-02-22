import SwiftUI

struct RAGRepositorySkillDisplayItem: Identifiable {
  let id: String
  let title: String
  let priority: Int
}

struct RAGRepositorySkillsSection: View {
  let skills: [RAGRepositorySkillDisplayItem]
  let onManage: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Guidance Skills", systemImage: "lightbulb")
          .font(.subheadline.weight(.semibold))

        Spacer()

        Button {
          onManage()
        } label: {
          Label("Manage", systemImage: "gear")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if skills.isEmpty {
        Text("No skills configured for this repository")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(skills.prefix(3)) { skill in
            HStack(spacing: 6) {
              Circle()
                .fill(.green)
                .frame(width: 6, height: 6)

              Text(skill.title.isEmpty ? "Untitled" : skill.title)
                .font(.caption)
                .lineLimit(1)

              Spacer()

              Text("Priority \(skill.priority)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }

          if skills.count > 3 {
            Text("+ \(skills.count - 3) more")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}