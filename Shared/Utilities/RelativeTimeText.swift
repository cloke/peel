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
  
  /// Timer that fires every 60 seconds to update the display
  @State private var tick = 0
  
  private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
  
  init(_ date: Date, presentation: Date.RelativeFormatStyle.Presentation = .named) {
    self.date = date
    self.style = presentation
  }
  
  var body: some View {
    Text(date, format: .relative(presentation: style))
      .onReceive(timer) { _ in
        tick += 1  // Force view refresh
      }
      .id(tick)  // Ensure the text actually re-renders
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
