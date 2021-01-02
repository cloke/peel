//
//  Git_DiffView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

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


struct DiffView_Previews: PreviewProvider {
  static var previews: some View {
    DiffView(diff: [DiffLine]())
  }
}
