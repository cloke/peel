//
//  LogEntryRowView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

struct LogEntryRowView: View {
  let log: LogEntry
  
  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Text(log.commit)
        Spacer()
        Text(relativeDate(date: log.date))
      }
      Text(log.message.first ?? "")
        .lineLimit(2)
        .truncationMode(.tail)
        .padding(.top, 5)
      Spacer()
      HStack {
        Spacer()
        Text(log.author)
      }
    }
  }
  
  func relativeDate(date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}


struct LogEntryRowView_Previews: PreviewProvider {
  static var previews: some View {
    LogEntryRowView(log: LogEntry(commit: "123"))
  }
}
