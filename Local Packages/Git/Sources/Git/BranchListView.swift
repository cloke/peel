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

  public var type: Model.BranchType
  public var selected: () -> ()
  public var activated: () -> ()
  public var push: () -> ()
  
  var body: some View {
    HStack {
      Toggle(isOn: $branch.isSelected, label: {})
        .toggleStyle(.checkbox)
      Text(branch.name)
        .fontWeight(branch.isActive ? .bold : .regular)
        .gesture(
          TapGesture(count: 1)
            .onEnded({ selected() })
        )
        .highPriorityGesture(
          TapGesture(count: 2)
            .onEnded({ activated() })
        )
      Spacer()
      Text(upDown)
        .task {
          do {
            if type == .local {
              let status = try await Commands.revList(repository: repository, branchA: "origin/\(branch.name)", branchB: branch.name)
              upDown = "(⇣\(status.0) / \(status.1) ⇡)"
            }
          } catch {}
        }
      Button {
        push()
      } label: { Image(systemName: "square.and.arrow.up") }
    }
  }
}

public struct BranchListView: View {
  @Environment(Model.Repository.self) var repository
  
  @State private var isShowing = false
  // TODO: Should we persist this as state?
  @State private var isExpanded = false
  @State private var multiSelection = Set<UUID>()
  
  
  @Binding public var localBranches: [Model.Branch]
  public var label: String
  public var location: Model.BranchType = .remote
    
  public var body: some View {
    List {
    Section(label, isExpanded: $isExpanded) {
      ForEach(localBranches.indices, id: \.self) { index in
        NavigationLink(value: localBranches[index].name) {
          BranchListItemView(
            branch: $localBranches[index],
            type: location,
            selected: {},
            activated: {
              Task { @MainActor in
                let branch = localBranches[index].name
                _ = try await Commands.checkout(branch: branch , from: repository)
                repository.activate(branch: localBranches[index])
              }
            },
            push: {
              Task {
                let branch = localBranches[index]
                try? await repository.push(branch: branch)
              }
            }
          )
        }
        .navigationDestination(for: String.self) { branchName in
          HistoryListView(branch: branchName)
        }
        .font(.footnote)
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
          Button {
            Task {
              try? await repository.delete(branches: localBranches.filter { $0.isSelected == true })
            }
          } label: {
            Text("Delete Branch")
            Image(systemName: "trash")
          }
        }
      }
    }
//    label: {
//      HStack {
//        Text("\(label) (\(localBranches.count))")
//        Spacer()
//        if isExpanded {
//          Button {
//            Task {
//              await repository.load()
//            }
//          } label: { Image(systemName: "arrow.counterclockwise.icloud") }
//        }
//      }
//    }
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

struct BranchListView_Previews: PreviewProvider {
  static var previews: some View {
    BranchListView(localBranches: .constant([]), label: "Test")
  }
}
#endif
