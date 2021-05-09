//
//  Git_FileListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/28/20.
//

import SwiftUI

struct FileListItemView: View {
  var path: String
  @State var toggleState: Bool
  
  var body: some View {
    HStack {
      Toggle(isOn: $toggleState) { EmptyView() }
        .onChange(of: toggleState) {
          $0 ? ViewModel.shared.add(path: path) : ViewModel.shared.reset(path: path)
        }
      Text(path)
        .truncationMode(.head)
        .lineLimit(1)
      Spacer()
    }
  }
}

struct FileListView: View {
  @State private var commitMessage: String = ""
  @State private var changes = [FileDescriptor]()
  @State private var diff = Diff()
  @StateObject private var viewModel: ViewModel = .shared

  var body: some View {
    NavigationView {
      List {
        TextEditor(text: $commitMessage)
          .frame(height: 100)
        Button("Commit Changes") {
          ViewModel.shared.commit(message: commitMessage) { _ in
            commitMessage = ""
            ViewModel.shared.status() { changes = $0 }
          }
        }.disabled(commitMessage.count == 0)
        ForEach(changes) { change in
          FileListItemView(path: change.path, toggleState: ![.modifiedMe, .untracked].contains(change.status)) //change.status != "??" ? false : true)
            .contentShape(Rectangle())
            .background(color(status: change.status))
            .foregroundColor(color(status: change.status).isDarkColor == true ? .white : .black)
            .onTapGesture {
              DispatchQueue.main.async {
                let str = change.path
                ViewModel.shared.diff(path: str) { diff = $0 }
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
                let str = change.path
                  .replacingOccurrences(of: " ", with: "\\ ")
                ViewModel.shared.restore(path: str) { _ in
                  ViewModel.shared.status() { changes = $0 }
                }
              }
              label: {
                Text("Revert file")
                Image(systemName: "arrow.uturn.backward")
              }
            }
        }
      }
      DiffView(diff: diff)
    }
    .onReceive(viewModel.$selectedRepository) { _ in
      DispatchQueue.main.async {
        ViewModel.shared.status() { changes = $0 }
      }
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

struct FileListView_Previews: PreviewProvider {
  static var previews: some View {
    FileListView()
  }
}
