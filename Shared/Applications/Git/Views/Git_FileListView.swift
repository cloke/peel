//
//  Git_FileListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/28/20.
//

import SwiftUI

extension Git {
  struct FileListView: View {
    @ObservedObject private var viewModel = ViewModel()
    @State private var commitOrPath: String = ""
    @State private var commitMessage: String = ""
    
    var body: some View {
      NavigationView {
        List {
          TextEditor(text: $commitMessage)
          Button("Commit Changes") {
            viewModel.commit(message: commitMessage) {
              commitMessage = ""
              viewModel.status()
            }
          }
          ForEach(viewModel.changes, id: \.self) { string in
            Text(string)
              .truncationMode(.head)
              .lineLimit(1)
              .clipped()
              .background(color(string: string))
              .contentShape(Rectangle())
              .onTapGesture {
                var file = string.split(separator: " ")
                file.removeFirst()
                print(file)
                DispatchQueue.main.async {
                  self.commitOrPath = file.joined(separator: "")

                }
              }
          }
        }
        .onReceive(viewModel.$changes, perform: {
          print($0)
        })
        if commitOrPath != "" {
          DiffView(commitOrPath: commitOrPath)
        }
      }
      .onAppear {
        viewModel.status()
      }
    }
    
    func color(string: String) -> Color {
      switch string {
      case let str where str.starts(with: "AM"): return .blue
      case let str where str.starts(with: "A"): return Git.green
      case let str where str.starts(with: " M"): return .yellow
      case let str where str.starts(with: "??"): return .purple
      default: return .clear
      }
    }
  }
}

struct Git_FileListView_Previews: PreviewProvider {
  static var previews: some View {
    Git.FileListView()
  }
}
