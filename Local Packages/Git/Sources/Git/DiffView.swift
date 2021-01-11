//
//  Git_DiffView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

struct DiffView: View {
  var diff: Diff
  
  var body: some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        VStack(alignment: .leading) {
          ForEach(diff.files) { file in
            DisclosureGroup(file.label) {
              ForEach(file.chunks) { chunk in
                Text(chunk.chunk)
                ForEach(chunk.lines) { line in
                HStack {
                  if line.lineNumber != 0 {
                    Text(line.lineNumber.description)
                  }
                  Text(line.line)
                    .padding(.horizontal)
                  Spacer()
                }
                .background(lineColor(line.status))
              }
              }
            }
          }
          Spacer()
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
    DiffView(diff: Diff())
  }
}
