//
//  Git_DiffView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

struct LineNumberView: View {
  var status: String
  var number: String
  
  var body: some View {
    HStack {
      Text(number)
        .padding(.leading)
        .opacity(status == "+" ? 0 : 1)
      Text(number)
        .opacity(status == "-" ? 0 : 1)
    }
  }
}

public struct DiffView: View {
  public var diff: Diff
  
  public init(diff: Diff) {
    self.diff = diff
  }
  
  public var body: some View {
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
                      LineNumberView(status: line.status, number: line.lineNumber.description)
                        .font(.body.monospaced())
                    }
                    Text(line.line)
                      .padding(.horizontal)
                      .font(.body.monospaced())
                    Spacer()
                  }
                  .background(lineColor(line.status))
                }
              }
            }
          }
          Spacer()
        }
        .textSelection(.enabled)
        .frame(width: geometry.size.width)
        .frame(minHeight: geometry.size.height)
      }
    }
  }
  
  func lineColor(_ symbol: String) -> Color {
    switch symbol {
    case "+": return .gitGreen
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
