//
//  Repositories_RootView.swift
//  KitchenSync
//
//  Created by Copilot on 2/13/26.
//

import SwiftUI

struct Repositories_RootView: View {
  #if os(macOS)
  @Environment(MCPServerService.self) private var mcpServer
  #endif

  enum Scope: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var title: String {
      switch self {
      case .local: "Local"
      case .remote: "Remote"
      }
    }

    var icon: String {
      switch self {
      case .local: "folder"
      case .remote: "globe"
      }
    }
  }

  let initialScope: Scope?
  @AppStorage("repositories.selectedScope") private var selectedScopeRaw = Scope.remote.rawValue
  @State private var hasAppliedInitialScope = false
  @State private var localRootResetToken = UUID()
  @State private var remoteRootResetToken = UUID()

  init(initialScope: Scope? = nil) {
    self.initialScope = initialScope
  }

  private var currentScope: Scope {
    Scope(rawValue: selectedScopeRaw) ?? .remote
  }

  var body: some View {
    VStack(spacing: 0) {
      scopePicker
      Divider()
      scopeContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    #if os(macOS)
    .toolbar {
      ToolSelectionToolbar()
    }
    #endif
    .onAppear {
      guard !hasAppliedInitialScope else { return }
      hasAppliedInitialScope = true
      if let initialScope {
        selectedScopeRaw = initialScope.rawValue
      }
    }
    #if os(macOS)
    .onChange(of: mcpServer.lastUIAction?.id) {
      guard let action = mcpServer.lastUIAction else { return }
      switch action.controlId {
      case "repositories.resetScope":
        resetScope(currentScope)
        mcpServer.recordUIActionHandled(action.controlId)
      case "repositories.openLocal":
        selectScope(.local)
        mcpServer.recordUIActionHandled(action.controlId)
      case "repositories.openRemote":
        selectScope(.remote)
        mcpServer.recordUIActionHandled(action.controlId)
      default:
        break
      }
      mcpServer.lastUIAction = nil
    }
    #endif
  }

  // MARK: - Scope Picker

  /// Custom two-tab picker. Re-tapping the active tab resets it to root.
  private var scopePicker: some View {
    HStack(spacing: 0) {
      ForEach(Scope.allCases) { scope in
        scopeTab(scope)
      }
    }
    .padding(3)
    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 8)
  }

  private func scopeTab(_ scope: Scope) -> some View {
    Button {
      if currentScope == scope {
        resetScope(scope)
      } else {
        selectScope(scope)
      }
    } label: {
      Label(scope.title, systemImage: scope.icon)
        .font(.callout.weight(currentScope == scope ? .semibold : .regular))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          currentScope == scope
            ? Color.primary.opacity(0.08)
            : Color.clear,
          in: RoundedRectangle(cornerRadius: 8)
        )
        .foregroundStyle(currentScope == scope ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.15), value: currentScope)
    .help(currentScope == scope
      ? "Return \(scope.title) to its root"
      : "Switch to \(scope.title)")
  }

  // MARK: - Content

  @ViewBuilder
  private var scopeContent: some View {
    switch currentScope {
    case .local:
      #if os(macOS)
      Git_RootView(showToolSelectionToolbar: false)
        .id(localRootResetToken)
      #else
      RepositoriesLocalUnavailableView()
      #endif
    case .remote:
      Github_RootView(showToolSelectionToolbar: false)
        .id(remoteRootResetToken)
    }
  }

  // MARK: - Actions

  private func selectScope(_ scope: Scope) {
    if scope == .remote {
      clearRemoteDetailSelection()
    }
    selectedScopeRaw = scope.rawValue
  }

  private func resetScope(_ scope: Scope) {
    switch scope {
    case .local:
      localRootResetToken = UUID()
    case .remote:
      clearRemoteDetailSelection()
      remoteRootResetToken = UUID()
    }
  }

  private func clearRemoteDetailSelection() {
    UserDefaults.standard.set("", forKey: "github.automationSelectedFavoriteKey")
    UserDefaults.standard.set("", forKey: "github.automationSelectedRecentPRKey")
    UserDefaults.standard.set("", forKey: "github.selectedFavoriteKey")
    UserDefaults.standard.set("", forKey: "github.selectedRecentPRKey")
  }
}

// MARK: - iOS Unavailable

private struct RepositoriesLocalUnavailableView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Local Git Unavailable", systemImage: "folder.badge.questionmark")
      } description: {
        Text("Local repository management requires filesystem access and is only available on macOS.")
      } actions: {
        Text("Switch to Remote for GitHub repositories.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("Local")
    }
  }
}

#Preview {
  Repositories_RootView()
}