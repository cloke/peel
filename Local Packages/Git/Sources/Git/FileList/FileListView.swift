//
//  FileListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/28/20.
//

import SwiftUI

#if os(macOS)
struct FileListView: View {
  @Bindable var repository: Model.Repository
  @State private var commitMessage: String = ""
  @State private var diff = Diff()
  @FocusState private var commitIsFocused: Bool
  
  var body: some View {
    HSplitView {
      VStack(spacing: 12) {
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Text("Message")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextEditor(text: $commitMessage)
              .font(.body)
              .textEditorStyle(.plain)
              .frame(minHeight: 160)
              .focused($commitIsFocused)
              .overlay(alignment: .topLeading) {
                if commitMessage.isEmpty {
                  Text("Enter commit message")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.leading, 4)
                }
              }
            HStack {
              Button("Commit") {
                Task {
                  _ = try await Commands.commit(repository: repository, message: commitMessage)
                  commitMessage = ""
                  await repository.refreshStatus()
                }
              }
              .buttonStyle(.borderedProminent)
              .disabled(commitMessage.isEmpty)
              Spacer()
              Button {
                Task {
                  try await Commands.Stash.push(repository: repository)
                }
              } label: {
                Label("Stash", systemImage: "square.stack.3d.up")
              }
              .buttonStyle(.bordered)
            }
          }
          .padding(.vertical, 4)
        }
        
        List {
          Section("Changes") {
            if repository.status.isEmpty {
              ContentUnavailableView {
                Label("Working Tree Clean", systemImage: "checkmark.circle")
              } description: {
                Text("No local changes detected")
              }
              .frame(maxWidth: .infinity, alignment: .center)
              .listRowSeparator(.hidden)
            } else {
              ForEach(repository.status) { file in
                FileListItemView(file: file, toggleState: [.modifiedMe].contains(file.status)) //change.status != "??" ? false : true)
                  .contentShape(Rectangle())
                  .onTapGesture {
                    Task {
                      let str = file.path
                      diff = try await Commands.diff(repository: repository, path: str)
                    }
                  }
                  .contextMenu {
                    Button {} label: {
                      Text("Ignore")
                      Image(systemName: "pencil.slash")
                    }
                    Button {} label: {
                      Text("Move to trash")
                      Image(systemName: "trash")
                    }
                    Button {
                      let str = file.path
                        .replacingOccurrences(of: " ", with: "\\ ")
                      Task {
                        _ = try await Commands.restore(path: str, on: repository)
                        await repository.refreshStatus()
                      }
                    } label: {
                      Text("Revert file")
                      Image(systemName: "arrow.uturn.backward")
                    }
                  }
              }
            }
          }
        }
        .listStyle(.inset)
      }
      .frame(minWidth: 0, idealWidth: 360)
      
      DiffView(diff: diff)
        .frame(minWidth: 0)
    }
    .navigationTitle("Local Changes")
    .task {
      await repository.refreshStatus()
    }
    .environment(repository)
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
