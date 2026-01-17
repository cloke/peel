//
//  Git_BranchListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

#if os(macOS)
struct ListItem: Identifiable {
    let id: Int
    var isChecked: Bool
}

struct BranchListItemView: View {
  @Environment(Model.Repository.self) var repository
  @State private var upDown = ""
  
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
              let status = try await Commands.revList(repository: repository, branchA: "origin/\(branch.name)", branchB: branch.name)
              upDown = "(⇣\(status.0) / \(status.1) ⇡)"
            } else {
              upDown = ""
            }
          } catch {
            upDown = ""
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
  @State private var multiSelection = Set<UUID>()
  
  
  @Binding public var localBranches: [Model.Branch]
  public var label: String
  public var location: Model.BranchType = .remote
    
  public var body: some View {
    Section(isExpanded: $isExpanded) {
      if localBranches.isEmpty {
        Text("No branches")
          .foregroundStyle(.secondary)
          .font(.caption)
      }
      ForEach(localBranches.indices, id: \.self) { index in
        BranchListItemView(
          branch: $localBranches[index],
          refreshToken: refreshToken,
          type: location,
          selected: {},
          activated: {
            Task { @MainActor in
              let branch = localBranches[index].name
              _ = try await Commands.checkout(branch: branch , from: repository)
              repository.activate(branch: localBranches[index])
              refreshToken = UUID()
            }
          },
          push: {
            Task {
              let branch = localBranches[index]
              do {
                try await repository.push(branch: branch)
                refreshToken = UUID()
              } catch {
                pushError = "Failed to push \(branch.name): \(error.localizedDescription)"
              }
            }
          }
        )
        .tag(GitDestination.history(localBranches[index].name))
        .font(.footnote)
        .contentShape(Rectangle())
        .onTapGesture {
          selection = .history(localBranches[index].name)
        }
        .contextMenu {
          Button {
            Task {
              try? await repository.delete(branches: [localBranches[index]])
            }
          } label: {
            Text("Delete Branch")
            Image(systemName: "trash")
          }
        }
      }
    } header: {
      Button {
        withAnimation { isExpanded.toggle() }
      } label: {
        Label(label, systemImage: sectionIcon)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
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
