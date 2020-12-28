//
//  Git_DiffView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

extension Git {
  struct DiffView: View {
    @State private var diffLines = [DiffLine]()
    
    var commitOrPath: String
    
    var body: some View {
      GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading) {
            ForEach(diffLines) { diffLine in
              if diffLine.line.starts(with: "diff --git") {
                Divider()
              }
              HStack {
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
        .onAppear {
          loadDiff(commitOrPath: commitOrPath)
        }
        .onChange(of: commitOrPath, perform: {
          loadDiff(commitOrPath: $0)
        })
      }
    }
    
    func loadDiff(commitOrPath: String) {
      diffLines.removeAll()
      ViewModel.shared.diff(commit: commitOrPath) {
        print($0)
        diffLines = $0
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

struct Git_DiffView_Previews: PreviewProvider {
  static var previews: some View {
    Git.DiffView(commitOrPath: "Test")
  }
}
