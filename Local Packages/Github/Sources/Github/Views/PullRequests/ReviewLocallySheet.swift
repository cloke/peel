//
//  ReviewLocallySheet.swift
//  Github
//
//  Created by Copilot on 1/7/26.
//

import SwiftUI
import Git

#if os(macOS)
/// Sheet for setting up local PR review with worktrees
public struct ReviewLocallySheet: View {
  @Environment(\.dismiss) private var dismiss
  
  let pullRequest: Github.PullRequest
  let repository: Github.Repository
  
  @State private var service = ReviewLocallyService.shared
  @State private var selectedRepoPath: String = ""
  @State private var openInVSCode = true
  
  public init(pullRequest: Github.PullRequest, repository: Github.Repository) {
    self.pullRequest = pullRequest
    self.repository = repository
  }
  
  public var body: some View {
    VStack(spacing: 0) {
      // Header
      headerView
      
      Divider()
      
      // Content based on state
      contentView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      
      Divider()
      
      // Footer with actions
      footerView
    }
    .frame(width: 480, height: 400)
    .onAppear {
      // Auto-select matching repository if found
      autoSelectRepository()
    }
  }
  
  // MARK: - Header
  
  private var headerView: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "arrow.down.to.line.circle")
          .font(.title)
          .foregroundStyle(.blue)
        
        VStack(alignment: .leading, spacing: 2) {
          Text("Review Locally")
            .font(.headline)
          Text("PR #\(pullRequest.number): \(pullRequest.title ?? "Untitled")")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        
        Spacer()
      }
      
      HStack(spacing: 16) {
        Label(pullRequest.head.ref, systemImage: "arrow.triangle.branch")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Label(repository.full_name ?? repository.name, systemImage: "folder")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
  }
  
  // MARK: - Content
  
  @ViewBuilder
  private var contentView: some View {
    switch service.state {
    case .idle:
      repositorySelectionView
      
    case .checkingRepository:
      progressView(title: "Checking repository...", systemImage: "folder.badge.gearshape")
      
    case .fetchingRemote:
      progressView(title: "Fetching remote branch...", systemImage: "arrow.down.circle")
      
    case .creatingWorktree:
      progressView(title: "Creating worktree...", systemImage: "plus.rectangle.on.folder")
      
    case .openingVSCode:
      progressView(title: "Opening VS Code...", systemImage: "chevron.left.forwardslash.chevron.right")
      
    case .complete(let worktreePath):
      completionView(worktreePath: worktreePath)
      
    case .error(let message):
      errorView(message: message)
    }
  }
  
  // MARK: - Repository Selection
  
  private var repositorySelectionView: some View {
    VStack(spacing: 16) {
      // Instructions
      Text("Select the local clone of this repository to create a worktree for reviewing this PR.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      
      // Path input
      VStack(alignment: .leading, spacing: 8) {
        Text("Local Repository Path")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        HStack {
          TextField("Path to local repository", text: $selectedRepoPath)
            .textFieldStyle(.roundedBorder)
          
          Button("Browse...") {
            if let path = service.browseForRepository() {
              selectedRepoPath = path
            }
          }
        }
      }
      .padding(.horizontal)
      
      // Recent repositories
      if !service.recentRepositories.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Recent Repositories")
            .font(.caption)
            .foregroundStyle(.secondary)
          
          ScrollView {
            VStack(spacing: 4) {
              ForEach(service.recentRepositories) { repo in
                recentRepositoryRow(repo)
              }
            }
          }
          .frame(maxHeight: 120)
        }
        .padding(.horizontal)
      }
      
      // Options
      Toggle("Open in VS Code when ready", isOn: $openInVSCode)
        .padding(.horizontal)
      
      Spacer()
    }
    .padding(.top)
  }
  
  private func recentRepositoryRow(_ repo: ReviewLocallyService.LocalRepository) -> some View {
    Button {
      selectedRepoPath = repo.path
    } label: {
      HStack {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
        
        VStack(alignment: .leading, spacing: 2) {
          Text(repo.name)
            .font(.callout)
          Text(repo.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        
        Spacer()
        
        if service.repositoryMatches(local: repo, githubRepo: repository) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(selectedRepoPath == repo.path ? Color.accentColor.opacity(0.1) : Color.clear)
      .cornerRadius(6)
    }
    .buttonStyle(.plain)
  }
  
  // MARK: - Progress View
  
  private func progressView(title: String, systemImage: String) -> some View {
    VStack(spacing: 16) {
      Spacer()
      
      Image(systemName: systemImage)
        .font(.system(size: 48))
        .foregroundStyle(.blue)
        .symbolEffect(.pulse)
      
      Text(title)
        .font(.headline)
      
      ProgressView()
        .scaleEffect(1.2)
      
      Spacer()
    }
  }
  
  // MARK: - Completion View
  
  private func completionView(worktreePath: String) -> some View {
    VStack(spacing: 16) {
      Spacer()
      
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 64))
        .foregroundStyle(.green)
      
      Text("Worktree Created!")
        .font(.title2)
        .fontWeight(.semibold)
      
      VStack(spacing: 4) {
        Text("Location:")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(worktreePath)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      
      HStack(spacing: 12) {
        Button {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktreePath)
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        
        Button {
          try? VSCodeLauncher.open(path: worktreePath)
        } label: {
          Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .buttonStyle(.borderedProminent)
      }
      
      Spacer()
    }
  }
  
  // MARK: - Error View
  
  private func errorView(message: String) -> some View {
    VStack(spacing: 16) {
      Spacer()
      
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.red)
      
      Text("Failed to Create Worktree")
        .font(.headline)
      
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      
      Button("Try Again") {
        service.reset()
      }
      
      Spacer()
    }
  }
  
  // MARK: - Footer
  
  private var footerView: some View {
    HStack {
      if case .complete = service.state {
        // Done state
      } else if case .error = service.state {
        // Error state
      } else {
        Button("Cancel") {
          service.reset()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      
      Spacer()
      
      switch service.state {
      case .idle:
        Button("Create Worktree") {
          Task {
            await service.reviewLocally(
              pullRequest: pullRequest,
              localRepoPath: selectedRepoPath,
              openInVSCode: openInVSCode
            )
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedRepoPath.isEmpty)
        .keyboardShortcut(.defaultAction)
        
      case .complete:
        Button("Done") {
          service.reset()
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        
      case .error:
        Button("Close") {
          service.reset()
          dismiss()
        }
        
      default:
        EmptyView()
      }
    }
    .padding()
  }
  
  // MARK: - Helpers
  
  private func autoSelectRepository() {
    // Find a matching repository in recents
    if let match = service.recentRepositories.first(where: {
      service.repositoryMatches(local: $0, githubRepo: repository)
    }) {
      selectedRepoPath = match.path
    }
  }
}

#endif
