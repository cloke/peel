//
//  Git_FileListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/28/20.
//

import SwiftUI

struct CheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    return HStack {
      configuration.label
      Spacer()
      Image(systemName: configuration.isOn ? "checkmark.square" : "square")
        .resizable()
        .frame(width: 22, height: 22)
        .onTapGesture { configuration.isOn.toggle() }
    }
  }
}

extension Git {
  struct FileListItemView: View {
    var path: String
    @State var toggleState: Bool

    var body: some View {
      HStack {
        Toggle(isOn: $toggleState) { EmptyView() }
          .onChange(of: toggleState) {
            let path = String(self.path.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            $0 ? ViewModel.shared.add(path: path) : ViewModel.shared.unadd(path: path)
          }
        Text(path)
          .truncationMode(.head)
          .lineLimit(1)
        Spacer()
      }
    }
  }
  
  struct FileListView: View {
    @ObservedObject private var viewModel = ViewModel()
    @State private var commitOrPath: String = ""
    @State private var commitMessage: String = ""
    
    var body: some View {
      NavigationView {
        List {
          TextEditor(text: $commitMessage)
            .frame(height: 100)
          Button("Commit Changes") {
            viewModel.commit(message: commitMessage) {
              commitMessage = ""
              viewModel.status()
            }
          }
          ForEach(viewModel.changes, id: \.self) { string in
            FileListItemView(path: string, toggleState: string.starts(with: "??") ? false : true)
              .contentShape(Rectangle())
              .background(color(string: string))
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
