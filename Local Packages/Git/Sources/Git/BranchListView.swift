//
//  Git_BranchListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI
import OSLog

#if os(macOS)
struct ListItem: Identifiable {
    let id: Int
    var isChecked: Bool
}

struct BranchListItemView: View {
  @Environment(Model.Repository.self) var repository
  @State private var upDown = ""

  private let logger = Logger(subsystem: "Peel", category: "Git.BranchRow")
  
  @Binding var branch: Model.Branch
  let refreshToken: UUID

  public var type: Model.BranchType
  public var selected: () -> ()
  public var activated: () -> ()
  public var push: () -> ()
  
  var body: some View {
    HStack {
      Image(systemName: branch.isActive ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(branch.isActive ? Color.accentColor : Color.secondary)
      Text(branch.name)
        .fontWeight(branch.isActive ? .bold : .regular)
      Spacer()
      Text(upDown)
        .task(id: refreshToken) {
          do {
            if type == .local {
              let remoteNames = Set(repository.remoteBranches.map { name in
                name.name.replacingOccurrences(of: "refs/heads/", with: "")
              })
              let hasUpstream = remoteNames.contains(branch.name)
              guard hasUpstream else {
                upDown = ""
                return
              }
              let startTime = Date()
              let status = try await Commands.revList(repository: repository, branchA: "origin/\(branch.name)", branchB: branch.name)
              upDown = "(⇣\(status.0) / \(status.1) ⇡)"
              let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
              logger.debug("rev-list \(branch.name) in \(durationMs)ms")
            } else {
              upDown = ""
            }
          } catch {
            upDown = ""
            logger.error("rev-list failed for \(branch.name): \(String(describing: error))")
          }
        }
      Button {
        push()
      } label: {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(.borderless)
      .help("Push Branch")
    }
    .simultaneousGesture(
      TapGesture(count: 2)
        .onEnded({ activated() })
    )
  }
}

public struct BranchListView: View {
  @Environment(Model.Repository.self) var repository
  @Binding var selection: GitDestination?
  
  @State private var isShowing = false
  @State private var pushError: String?
  @State private var refreshToken = UUID()
  // TODO: Should we persist this as state?
  @State private var isExpanded = false
  @State private var hasLoadedBranches = false
  @State private var multiSelection = Set<UUID>()
  
  
  @Binding public var localBranches: [Model.Branch]
  public var label: String
  public var location: Model.BranchType = .remote
    
  public var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      if localBranches.isEmpty {
        Text("No branches")
          .foregroundStyle(.secondary)
          .font(.caption)
      }
      ForEach($localBranches) { $branch in
        BranchListItemView(
          branch: $branch,
          refreshToken: refreshToken,
          type: location,
          selected: {},
          activated: {
            Task { @MainActor in
              let name = branch.name
              _ = try await Commands.checkout(branch: name, from: repository)
              repository.activate(branch: branch)
              refreshToken = UUID()
            }
          },
          push: {
            Task {
              let currentBranch = branch
              do {
                try await repository.push(branch: currentBranch)
                refreshToken = UUID()
              } catch {
                pushError = "Failed to push \(currentBranch.name): \(error.localizedDescription)"
              }
            }
          }
        )
        .tag(GitDestination.history(branch.name))
        .font(.footnote)
        .contentShape(Rectangle())
        .onTapGesture {
          selection = .history(branch.name)
          UserDefaults.standard.set(branch.name, forKey: "git.selectedBranchName")
        }
        .contextMenu {
          Button {
            Task {
              try? await repository.delete(branches: [branch])
            }
          } label: {
            Text("Delete Branch")
            Image(systemName: "trash")
          }
        }
      }
    } label: {
      Label(label, systemImage: sectionIcon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .alert("Push Failed", isPresented: .constant(pushError != nil)) {
      Button("OK") { pushError = nil }
    } message: {
      Text(pushError ?? "")
    }
    .sheet(isPresented: $isShowing) {
      BranchRepositoryView() { [self] in
        isShowing = false
        Task {
          await repository.load()
        }
      }
      .padding()
      .frame(width: 300, height: 100)
    }
    .contextMenu {
      Button {
        isShowing = true
      } label: {
        Text("Create Branch")
        Image(systemName: "arrow.triangle.branch")
      }
    }
    .onChange(of: isExpanded) { _, newValue in
      guard location == .remote, newValue, !hasLoadedBranches else { return }
      Task { @MainActor in
        await repository.loadBranches(branchType: .remote)
        hasLoadedBranches = true
      }
    }
  }

  private var sectionIcon: String {
    switch location {
    case .local:
      return "arrow.triangle.branch"
    case .remote:
      return "cloud"
    }
  }
}

struct BranchRepositoryView: View {
  @Environment(Model.Repository.self) var repository
  @State private var name = ""
  
  public var callback: (() -> ())? = nil
  
  var body: some View {
    TextField("Branch Name", text: $name)
    HStack {
      Button { callback?() }
    label: { Text("Cancel") }
      Spacer()
      Button {
        Task {
          _ = try? await Commands.Branch.create(name: name, on: repository)
          callback?()
        }
      }
    label: { Text("Create") }
    }
  }
}

#Preview {
  BranchListView(
    selection: .constant(nil),
    localBranches: .constant([]),
    label: "Test"
  )
}
#endif
