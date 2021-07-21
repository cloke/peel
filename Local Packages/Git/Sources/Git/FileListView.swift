//
//  Git_FileListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/28/20.
//

import SwiftUI
import CrunchyCommon

struct FileListItemView: View {
  @EnvironmentObject var repository: Model.Repository
  var path: String
  @State var toggleState: Bool
  
  var body: some View {
    HStack {
      Toggle(isOn: $toggleState) { EmptyView() }
        .onChange(of: toggleState) {
          $0 ? Commands.add(to: repository, path: path) : Commands.reset(path: path, on: repository)
        }
      Text(path)
        .truncationMode(.head)
        .lineLimit(1)
      Spacer()
    }
  }
}

struct FileListView: View {
  @ObservedObject var repository: Model.Repository
  @State private var commitMessage: String = ""
  @State private var diff = Diff()
  
  var body: some View {
    NavigationView {
      List {
        TextEditor(text: $commitMessage)
          .frame(height: 100)
        HStack {
          Button("Commit") {
            Commands.commit(repository: repository, message: commitMessage) { _ in
              commitMessage = ""
              repository.refreshStatus()
            }
          }.disabled(commitMessage.count == 0)
          Spacer()
          Button { Commands.Stash.push(repository: repository) }
            label: {
              Image(systemName: "square.stack.3d.up")
              Text("Stash")
            }
        }
        ForEach(repository.status) { change in
          FileListItemView(path: change.path, toggleState: ![.modifiedMe, .untracked, .unknown].contains(change.status)) //change.status != "??" ? false : true)
            .contentShape(Rectangle())
            .background(color(status: change.status))
            .foregroundColor(color(status: change.status).isDarkColor == true ? .white : .black)
            .onTapGesture {
              DispatchQueue.main.async {
                let str = change.path
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
                let str = change.path
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

//struct FileListView_Previews: PreviewProvider {
//  static var previews: some View {
//    FileListView()
//      .environmentObject(Model.Repository())
//  }
//}
