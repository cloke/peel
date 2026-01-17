//
//  GitRootView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/20/20.
//  Fixed deprecated Alert on 1/7/26
//  Updated for SwiftData on 1/7/26
//

import SwiftUI
import SwiftData
import Git

struct Git_RootView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \SyncedRepository.name) private var syncedRepos: [SyncedRepository]
  
  @State private var viewModel: ViewModel = .shared
  @State private var repoNotFoundError = false
  @State private var isCloning = false
  @State private var hasLoadedFromSwiftData = false
  @State private var activeSecurityScopedURL: URL?

  var body: some View {
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
        GitRootView(repository: viewModel.selectedRepository)
      }
    }
    .toolbar {
      ToolSelectionToolbar()
      RepositoriesMenuToolbarItem(
        repositories: viewModel.repositories,
        selectedRepository: $viewModel.selectedRepository,
        onAddRepository: { addRepository() },
        onCloneRepository: { isCloning = true }
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
    }
    .onChange(of: viewModel.selectedRepository.path) { _, _ in
      saveSelectionToSwiftData()
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
  
  private func loadFromSwiftData() {
    var loadedRepos: [Model.Repository] = []
    
    for syncedRepo in syncedRepos {
      let repoId = syncedRepo.id
      let descriptor = FetchDescriptor<LocalRepositoryPath>(
        predicate: #Predicate { $0.repositoryId == repoId }
      )
      
      if let localPath = try? modelContext.fetch(descriptor).first {
        let repoPath = resolvedPath(for: localPath) ?? localPath.localPath
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