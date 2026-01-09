//
//  LogEntryRowView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

struct LogEntryRowView: View {
  let log: Model.LogEntry
  
  private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()
  
  var body: some View {
    VStack(alignment: .leading) {
      HStack(alignment: .bottom) {
        Text(log.commit)
          .font(.headline)
        Spacer()
        Text(relativeDate(date: log.date))
          .font(.subheadline)
      }
      Text(log.message)
        .padding(.top, 5)
        .lineLimit(2)
        .truncationMode(.tail)
        .font(.subheadline)
      Spacer()
      HStack {
        Spacer()
        Text(log.author)
          .font(.caption)
      }
    }
  }
  
  func relativeDate(date: Date) -> String {
    Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
  }
}


#Preview {
  LogEntryRowView(
    log: Model.LogEntry(
      commit: "123",
      date: Date() - 1000,
      author: "Phillp J. Fry",
      message: "It's just like the story of the grasshopper and the octopus. All year long the grasshopper kept burying acorns for winter while the octopus mooched off his girlfriend and watched TV. Then the winter came, and the grasshopper died, and the octopus ate all his acorns and also he got a racecar. Is any of this getting through to you?"
    )
  )
  .frame(width: 200, height: 80)
}
