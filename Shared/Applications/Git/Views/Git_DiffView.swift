//
//  Git_DiffView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

extension Git {
  struct DiffView: View {
    var diff: [DiffLine]
    
    var body: some View {
      GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading) {
            ForEach(diff) { diffLine in
              if diffLine.line.starts(with: "diff --git") {
                Divider()
              }
              HStack {
                if diffLine.lineNumber != 0 {
                  Text(diffLine.lineNumber.description)
                }
                Text(diffLine.line)
                  .padding(.horizontal)
                Spacer()
              }
              .background(lineColor(diffLine.status))
            }
          }
          .frame(width: geometry.size.width)
          .frame(minHeight: geometry.size.height)
        }
      }
    }
    
    func lineColor(_ symbol: String) -> Color {
      switch symbol {
      case "+": return Git.green
      case "-": return .red
      default: return .clear
      }
    }
  }
}

internal extension NSTextCheckingResult {
  func group(_ group: Int, in string: String) -> String? {
    let nsRange = range(at: group)
    if range.location != NSNotFound {
      return Range(nsRange, in: string)
        .map { range in String(string[range]) }
    }
    return nil
  }
}
struct Git_DiffView_Previews: PreviewProvider {
  static var previews: some View {
    Git.DiffView(diff: [Git.DiffLine]())
  }
}
