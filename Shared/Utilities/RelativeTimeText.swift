//
//  RelativeTimeText.swift
//  Peel
//
//  Auto-updating relative time display (e.g., "2 minutes ago")
//

import SwiftUI

/// A Text view that displays a relative time and auto-updates every minute
struct RelativeTimeText: View {
  let date: Date
  let style: Date.RelativeFormatStyle.Presentation

  init(_ date: Date, presentation: Date.RelativeFormatStyle.Presentation = .named) {
    self.date = date
    self.style = presentation
  }

  var body: some View {
    TimelineView(.everyMinute) { _ in
      Text(date, format: .relative(presentation: style))
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    RelativeTimeText(Date())
    RelativeTimeText(Date().addingTimeInterval(-60))
    RelativeTimeText(Date().addingTimeInterval(-3600))
    RelativeTimeText(Date().addingTimeInterval(-86400))
  }
  .padding()
}
