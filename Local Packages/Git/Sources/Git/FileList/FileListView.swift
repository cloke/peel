//
//  FileListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/28/20.
//

import SwiftUI
import CrunchyCommon

#if os(macOS)
struct FileListView: View {
  @ObservedObject var repository: Model.Repository
  @State private var commitMessage: String = ""
  @State private var diff = Diff()
  @FocusState private var commitIsFocused: Bool
  
  var body: some View {
    NavigationView {
      List {
        ZStack {
          TextEditor(text: $commitMessage)
            .frame(height: 100)
            .focused($commitIsFocused)
          withAnimation {
            Text("Enter commit message")
              .opacity(commitIsFocused ? 0 : 1)
              .disabled(true)
          }
        }
        HStack {
          Button("Commit") {
            Commands.commit(repository: repository, message: commitMessage) { _ in
              commitMessage = ""
              repository.refreshStatus()
            }
          }
          .disabled(commitMessage.count == 0)
          Spacer()
          Button { Commands.Stash.push(repository: repository) }
        label: {
          Image(systemName: "square.stack.3d.up")
          Text("Stash")
        }
        }
        ForEach(repository.status) { file in
          FileListItemView(file: file, toggleState: [.modifiedMe].contains(file.status)) //change.status != "??" ? false : true)
            .contentShape(Rectangle())
            .onTapGesture {
              DispatchQueue.main.async {
                let str = file.path
                Commands.diff(repository: repository, path: str) { diff = $0 }
              }
            }
            .contextMenu {
              Button {}
            label: {
              Text("Ignore")
              Image(systemName: "pencil.slash")
            }
              Button {}
            label: {
              Text("Move to trash")
              Image(systemName: "trash")
            }
              Button {
                let str = file.path
                  .replacingOccurrences(of: " ", with: "\\ ")
                Commands.restore(path: str, on: repository) { _ in
                  repository.refreshStatus()
                }
              }
            label: {
              Text("Revert file")
              Image(systemName: "arrow.uturn.backward")
            }
            }
        }
      }
      .listStyle(.sidebar)
      DiffView(diff: diff)
    }
    .onAppear {
      print("Refresh status on: \(repository.name)")
      repository.refreshStatus()
    }
  }
  
  func color(status: FileStatus) -> Color {
    switch status {
    case .new: return .green
    case .staged: return .blue
    case .modifiedMe: return .yellow
    case .untracked: return .purple
    case .deleted: return .red
    default: return .clear
    }
  }
}
#endif

//struct FileListView_Previews: PreviewProvider {
//  static var previews: some View {
//    FileListView()
//      .environmentObject(Model.Repository())
//  }
//}
