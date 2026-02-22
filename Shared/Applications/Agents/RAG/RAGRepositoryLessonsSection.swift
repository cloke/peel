import SwiftUI

struct RAGRepositoryLessonDisplayItem: Identifiable {
  let id: String
  let fixDescription: String
  let confidence: Double
}

struct RAGRepositoryLessonsSection: View {
  let lessons: [RAGRepositoryLessonDisplayItem]
  let onManage: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Learned Lessons", systemImage: "brain")
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

      if lessons.isEmpty {
        Text("No lessons learned yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(lessons.prefix(3)) { lesson in
            HStack(spacing: 6) {
              Circle()
                .fill(lesson.confidence >= 0.7 ? .green : lesson.confidence >= 0.4 ? .orange : .red)
                .frame(width: 6, height: 6)

              Text(lesson.fixDescription)
                .font(.caption)
                .lineLimit(1)

              Spacer()

              Text("\(Int(lesson.confidence * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }

          if lessons.count > 3 {
            Text("+ \(lessons.count - 3) more")
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