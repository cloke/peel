//
//  FileListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/28/20.
//

import PeelUI
import SwiftUI
import OSLog

struct FileListView: View {
  @Bindable var repository: Model.Repository
  @State private var commitMessage: String = ""
  @State private var diff = Diff()
  @State private var selectedFilePath: String = ""
  @FocusState private var commitIsFocused: Bool
  @AppStorage("git.selectedStatusPath") private var selectedStatusPath: String = ""
  private let logger = Logger(subsystem: "Peel", category: "Git.LocalChanges")
  
  var body: some View {
    HSplitView {
      VStack(spacing: 12) {
        SectionCard("Message") {
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
        
        List(selection: $selectedFilePath) {
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
                      selectedFilePath = str
                      selectedStatusPath = str
                      await loadDiff(for: str, source: "tap")
                    }
                  }
                  .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                  .tag(file.path)
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
      .frame(minWidth: 200, idealWidth: 280, maxWidth: 360)
      
      DiffView(
        diff: diff,
        onStageHunk: { patch in
          try? await Commands.applyToIndex(patch: patch, in: repository)
          await repository.refreshStatus()
          // Reload diff to reflect staged change
          if !selectedFilePath.isEmpty {
            await loadDiff(for: selectedFilePath, source: "stage-hunk")
          }
        },
        onRevertHunk: { patch in
          try? await Commands.revertPatch(patch: patch, in: repository)
          await repository.refreshStatus()
          // Reload diff to reflect reverted change
          if !selectedFilePath.isEmpty {
            await loadDiff(for: selectedFilePath, source: "revert-hunk")
          }
        }
      )
        .frame(minWidth: 0, idealWidth: 0)
        .layoutPriority(1)
    }
    .navigationTitle("Local Changes")
    .task {
      await repository.refreshStatus()
      persistAvailableStatusPaths()
    }
    .onChange(of: repository.status.map { $0.path }) { _, _ in
      persistAvailableStatusPaths()
    }
    .onChange(of: selectedStatusPath) { _, newValue in
      guard !newValue.isEmpty else { return }
      selectedFilePath = newValue
      if let file = repository.status.first(where: { $0.path == newValue }) {
        Task {
          await loadDiff(for: file.path, source: "selection")
        }
      }
    }
    .environment(repository)
  }

  private func persistAvailableStatusPaths() {
    let paths = repository.status.map { $0.path }.sorted()
    UserDefaults.standard.set(paths, forKey: "git.availableStatusPaths")
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

  private func loadDiff(for path: String, source: String) async {
    let startTime = Date()
    #if DEBUG
    logger.notice("Diff load start for \(path, privacy: .public) (source: \(source, privacy: .public))")
    #endif
    do {
      let newDiff = try await Commands.diff(repository: repository, path: path)
      diff = newDiff
      let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
      #if DEBUG
      logger.notice("Diff load finished for \(path, privacy: .public) in \(durationMs)ms (files: \(newDiff.files.count), source: \(source, privacy: .public))")
      #endif
    } catch {
      #if DEBUG
      logger.notice("Diff load failed for \(path, privacy: .public) (source: \(source, privacy: .public)): \(error.localizedDescription, privacy: .public)")
      #endif
    }
  }
}

//struct FileListView_Previews: PreviewProvider {
//  static var previews: some View {
//    FileListView()
//      .environmentObject(Model.Repository())
//  }
//}
