//
//  GitRootView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI
import SwiftData
import Git

struct Git_RootView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \SyncedRepository.name) private var syncedRepos: [SyncedRepository]
  
  @State private var viewModel: ViewModel = .shared
  @State private var repoNotFoundError = false
  @State private var isCloning = false
  @State private var hasLoadedFromSwiftData = false
  @State private var activeSecurityScopedURL: URL?
  @AppStorage("git.selectedRepoPath") private var selectedRepoPath: String = ""

  var body: some View {
    contentView
  }

  private var contentView: some View {
    mainContent
      .toolbar {
        ToolSelectionToolbar()
        RepositoriesMenuToolbarItem(
          repositories: viewModel.repositories,
          selectedRepository: $viewModel.selectedRepository,
          onAddRepository: { addRepository() },
          onCloneRepository: { isCloning = true },
          onRemoveRepository: { removeSelectedRepository() }
        )
      }
      .alert("Repository Not Found", isPresented: $repoNotFoundError) {
        Button("OK", role: .cancel) { }
      } message: {
        Text("A git repository could not be found at that location.")
      }
      .sheet(isPresented: $isCloning) {
        CloneRepositoryView(isCloning: $isCloning)
          .padding()
          .frame(width: 300, height: 100)
      }
      .task {
        if !hasLoadedFromSwiftData {
          loadFromSwiftData()
          hasLoadedFromSwiftData = true
        }
        persistAvailableRepos()
        syncSelectedRepoFromStorage()
      }
      .onChange(of: viewModel.repositories.map { $0.path }) { _, _ in
        persistAvailableRepos()
        syncSelectedRepoFromStorage()
      }
      .onChange(of: viewModel.selectedRepository.path) { _, newValue in
        if !newValue.isEmpty, selectedRepoPath != newValue {
          selectedRepoPath = newValue
        }
        saveSelectionToSwiftData()
      }
      .onChange(of: selectedRepoPath) { _, _ in
        syncSelectedRepoFromStorage()
      }
      .onChange(of: mcpServer.lastUIAction?.id) {
        guard let action = mcpServer.lastUIAction else { return }
        switch action.controlId {
        case "git.openRepository":
          addRepository()
          mcpServer.recordUIActionHandled(action.controlId)
        case "git.cloneRepository":
          isCloning = true
          mcpServer.recordUIActionHandled(action.controlId)
        case "git.openInVSCode":
          let path = viewModel.selectedRepository.path
          if !path.isEmpty {
            Task {
              try? await VSCodeService.shared.open(path: path)
            }
            mcpServer.recordUIActionHandled(action.controlId)
          }
        default:
          break
        }
        mcpServer.lastUIAction = nil
      }
  }

  private var mainContent: some View {
    Group {
      if viewModel.selectedRepository.name == "N/A" || viewModel.selectedRepository.path.isEmpty {
        ContentUnavailableView {
          Label("No Repository", systemImage: "folder")
        } description: {
          Text("Open a git repository to get started")
        } actions: {
          Button("Open Repository") {
            addRepository()
          }
          .buttonStyle(.borderedProminent)
        }
      } else {
        GitRootView(
          repository: viewModel.selectedRepository,
          onOpenInVSCode: { path in
            Task {
              try? await VSCodeService.shared.open(path: path)
            }
          }
        )
      }
    }
  }
  
  private func addRepository() {
    let dialog = NSOpenPanel()
    dialog.title = "Choose a git repository"
    dialog.showsHiddenFiles = false
    dialog.canChooseFiles = false
    dialog.canChooseDirectories = true
    
    guard dialog.runModal() == .OK, let url = dialog.url else { return }
    
    if !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
      repoNotFoundError = true
      return
    }
    
    let name = url.lastPathComponent
    let path = url.path
    let bookmarkData = try? url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    
    // Add to SwiftData
    let syncedRepo = SyncedRepository(name: name, remoteURL: nil)
    modelContext.insert(syncedRepo)
    
    let localPath = LocalRepositoryPath(
      repositoryId: syncedRepo.id,
      localPath: path,
      bookmarkData: bookmarkData
    )
    modelContext.insert(localPath)
    
    try? modelContext.save()
    
    // Add to ViewModel
    let repo = Model.Repository(name: name, path: path)
    if let bookmarkData,
       let url = resolveBookmarkURL(bookmarkData: bookmarkData) {
      updateSecurityScope(with: url)
    }
    viewModel.repositories.append(repo)
    viewModel.selectedRepository = repo
  }

  private func removeSelectedRepository() {
    let path = viewModel.selectedRepository.path
    guard !path.isEmpty else { return }

    let pathDescriptor = FetchDescriptor<LocalRepositoryPath>(
      predicate: #Predicate { $0.localPath == path }
    )

    if let localPath = try? modelContext.fetch(pathDescriptor).first {
      if let repo = syncedRepos.first(where: { $0.id == localPath.repositoryId }) {
        modelContext.delete(repo)
      }
      modelContext.delete(localPath)
      try? modelContext.save()
    }

    viewModel.repositories.removeAll(where: { $0.path == path })
    if let nextRepo = viewModel.repositories.first {
      viewModel.selectedRepository = nextRepo
      selectedRepoPath = nextRepo.path
    } else {
      viewModel.selectedRepository = Model.Repository(name: "N/A", path: "")
      selectedRepoPath = ""
    }
  }
  
  private func loadFromSwiftData() {
    var loadedRepos: [Model.Repository] = []
    var seenPaths = Set<String>()  // Dedupe by path
    
    for syncedRepo in syncedRepos {
      let repoId = syncedRepo.id
      let descriptor = FetchDescriptor<LocalRepositoryPath>(
        predicate: #Predicate { $0.repositoryId == repoId }
      )
      
      if let localPath = try? modelContext.fetch(descriptor).first {
        let repoPath = resolvedPath(for: localPath) ?? localPath.localPath
        // Skip duplicates (same path already added)
        guard !seenPaths.contains(repoPath) else { continue }
        seenPaths.insert(repoPath)
        let repo = Model.Repository(name: syncedRepo.name, path: repoPath)
        loadedRepos.append(repo)
      }
    }
    
    viewModel.repositories = loadedRepos
    
    // Restore selection
    let settingsDescriptor = FetchDescriptor<DeviceSettings>()
    if let settings = try? modelContext.fetch(settingsDescriptor).first,
       let selectedId = settings.selectedRepositoryId,
       let syncedRepo = syncedRepos.first(where: { $0.id == selectedId }) {
      let repoId = syncedRepo.id
      let pathDescriptor = FetchDescriptor<LocalRepositoryPath>(
        predicate: #Predicate { $0.repositoryId == repoId }
      )
      if let localPath = try? modelContext.fetch(pathDescriptor).first {
        let repoPath = resolvedPath(for: localPath) ?? localPath.localPath
        let repo = Model.Repository(name: syncedRepo.name, path: repoPath)
        viewModel.selectedRepository = repo
      }
    } else if let firstRepo = loadedRepos.first {
      viewModel.selectedRepository = firstRepo
    }
  }
  
  private func saveSelectionToSwiftData() {
    guard !viewModel.selectedRepository.path.isEmpty else { return }
    
    let path = viewModel.selectedRepository.path
    let pathDescriptor = FetchDescriptor<LocalRepositoryPath>(
      predicate: #Predicate { $0.localPath == path }
    )
    
    guard let localPath = try? modelContext.fetch(pathDescriptor).first else { return }
    _ = resolvedPath(for: localPath)
    
    let settingsDescriptor = FetchDescriptor<DeviceSettings>()
    let settings: DeviceSettings
    if let existing = try? modelContext.fetch(settingsDescriptor).first {
      settings = existing
    } else {
      settings = DeviceSettings()
      modelContext.insert(settings)
    }
    
    settings.selectedRepositoryId = localPath.repositoryId
    settings.touch()
    try? modelContext.save()
  }

  private func persistAvailableRepos() {
    let repoPaths = Array(Set(viewModel.repositories.map { $0.path })).sorted()
    let repoNames = Array(Set(viewModel.repositories.map { $0.name })).sorted()
    UserDefaults.standard.set(repoPaths, forKey: "git.availableRepoPaths")
    UserDefaults.standard.set(repoNames, forKey: "git.availableRepoNames")
  }

  private func syncSelectedRepoFromStorage() {
    guard !selectedRepoPath.isEmpty else { return }
    if let repo = viewModel.repositories.first(where: { $0.path == selectedRepoPath }) {
      if viewModel.selectedRepository.path != repo.path {
        viewModel.selectedRepository = repo
      }
    }
  }

  private func resolvedPath(for localPath: LocalRepositoryPath) -> String? {
    guard let bookmarkData = localPath.bookmarkData,
          let url = resolveBookmarkURL(bookmarkData: bookmarkData) else {
      return nil
    }
    updateSecurityScope(with: url)
    if localPath.localPath != url.path {
      localPath.localPath = url.path
      try? modelContext.save()
    }
    return url.path
  }

  private func resolveBookmarkURL(bookmarkData: Data) -> URL? {
    var isStale = false
    return try? URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      bookmarkDataIsStale: &isStale
    )
  }

  private func updateSecurityScope(with url: URL) {
    if let activeSecurityScopedURL {
      activeSecurityScopedURL.stopAccessingSecurityScopedResource()
    }
    if url.startAccessingSecurityScopedResource() {
      activeSecurityScopedURL = url
    } else {
      activeSecurityScopedURL = nil
    }
  }
}

#Preview {
  Git_RootView()
}