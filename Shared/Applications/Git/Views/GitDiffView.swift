//
//  GitDiffView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

extension Git {
  struct DiffView: View {
    @ObservedObject private var viewModel = ViewModel()
    @State private var diffLines = [DiffLine]()
    
    var commitOrPath: String
    
    var body: some View {
      GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading) {
            ForEach(diffLines) { diffLine in
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
          loadDiff()
        }
        .onChange(of: commitOrPath, perform: { _ in
          loadDiff()
        })
      }
    }
    
    func loadDiff() {
      print("Load diff from Git.DiffView \(commitOrPath)")
      diffLines.removeAll()
      viewModel.diff(commit: commitOrPath) {
        diffLines = $0
      }
    }
    
    func lineColor(_ symbol: String) -> Color {
      switch symbol {
      case "+": return .green
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
