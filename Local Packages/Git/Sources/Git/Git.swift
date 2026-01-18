import SwiftUI

#if os(macOS)
import AppKit
enum GitDestination: Hashable {
  case localChanges
  case history(String)
}

public struct GitRootView: View {
  @Bindable public var repository: Model.Repository
  @State private var selection: GitDestination?
  @State private var worktreeDetailItem: WorktreeDetailItem?
  let onOpenInVSCode: ((String) -> Void)?
  
  public init(
    repository: Model.Repository,
    onOpenInVSCode: ((String) -> Void)? = nil
  ) {
    self.repository = repository
    self.onOpenInVSCode = onOpenInVSCode
    Task {
      await repository.load()
    }
  }
  
  public var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section("Repository") {
          LocalChangesListView()
            .tag(GitDestination.localChanges)
          StashListView(repository: repository)
        }
        BranchListView(
          selection: $selection,
          localBranches: $repository.localBranches,
          label: "Local Branches",
          location: .local
        )
        BranchListView(
          selection: $selection,
          localBranches: $repository.remoteBranches,
          label: "Remote Branches",
          location: .remote
        )
        WorktreeListView(
          onSelectWorktree: { worktree in
          worktreeDetailItem = WorktreeDetailItem(worktree: worktree)
          },
          onOpenInVSCode: onOpenInVSCode
        )
      }
      .listStyle(.sidebar)
    } detail: {
      switch selection {
      case .localChanges:
        FileListView(repository: repository)
      case .history(let branchName):
        HistoryListView(branch: branchName)
      case .none:
        ContentUnavailableView {
          Label("Select an Item", systemImage: "arrow.left")
        } description: {
          Text("Choose a section from the sidebar to view details")
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle(repository.name)
    .environment(repository)
    .sheet(item: $worktreeDetailItem, onDismiss: {
      worktreeDetailItem = nil
    }) { item in
      WorktreeDetailSheet(
        worktree: item.worktree,
        repository: repository,
        onClose: { worktreeDetailItem = nil },
        onOpenInVSCode: {
          onOpenInVSCode?(item.worktree.path)
        },
        onShowInFinder: {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.worktree.path)
        },
        onCopyPath: {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(item.worktree.path, forType: .string)
        },
        onToggleLock: {
          Task {
            if item.worktree.isLocked {
              try? await Commands.Worktree.unlock(path: item.worktree.path, on: repository)
            } else {
              try? await Commands.Worktree.lock(path: item.worktree.path, on: repository)
            }
          }
        },
        onDelete: {
          Task {
            try? await Commands.Worktree.remove(path: item.worktree.path, on: repository)
          }
        },
        onCreateBranch: { branchName in
          Task {
            let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let worktreeRepo = Model.Repository(name: repository.name, path: item.worktree.path)
            _ = try? await Commands.simple(arguments: ["checkout", "-b", trimmed], in: worktreeRepo)
          }
        }
      )
    }
  }
}
#endif
