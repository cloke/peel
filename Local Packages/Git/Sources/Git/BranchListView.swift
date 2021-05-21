//
//  Git_BranchListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

struct BranchListItemView: View {
  @EnvironmentObject var repository: Model.Repository
  @State private var upDown = ""
  
  public var name: String
  public var isActive: Bool
  public var type: Model.BranchType
  public var selected: () -> ()
  public var activated: () -> ()
  public var push: () -> ()
  var body: some View {
    Text(name)
      .fontWeight(isActive ? .bold : .regular)
      .gesture(
        TapGesture(count: 1)
          .onEnded({ selected() })
      )
      .highPriorityGesture(
        TapGesture(count: 2)
          .onEnded({ activated() })
      )
    Spacer()
    Button {
      push()
    } label: { Image(systemName: "square.and.arrow.up") }
    Text(upDown)
      .onAppear {
        Commands.revList(repository: repository, branchA: "origin/\(name)", branchB: name) {
          upDown = "(⇣\($0) / \($1) ⇡)"
        }
      }
  }
}

public struct BranchListView: View {
  @EnvironmentObject var repository: Model.Repository
  
  @State public private(set) var selection: String?
  @State private var isShowing = false
  // TODO: Should we persist this as state?
  @State private var isExpanded = false
  
  public var branches: [Model.Branch]
  public var label: String
  public var location: Model.BranchType = .remote
  
  public init(branches: [Model.Branch], label: String, location: Model.BranchType = .remote) {
    self.branches = branches
    self.label = label
    self.location = location
  }
  
  public var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(branches) { branch in
        NavigationLink(destination: HistoryListView(branch: branch.name), tag: branch.name, selection: self.$selection) {
          BranchListItemView(
            name: branch.name,
            isActive: branch.isActive,
            type: location,
            selected: {
              self.selection = branch.name
            },
            activated: {
              self.selection = branch.name
              Commands.checkout(branch: branch.name, from: repository) { _ in
                DispatchQueue.main.async {
                  repository.activate(branch: branch)
                }
              }
            },
            push: {
              repository.push(branch: branch)
            }
          )
        }
        .sheet(isPresented: $isShowing) {
          BranchRepositoryView() { [self] in
            isShowing = false
            repository.load()
          }
          .padding()
          .frame(width: 300, height: 100)
        }
        .contextMenu {
          Button { isShowing = true }
            label: {
              Text("Create Branch")
              Image(systemName: "arrow.triangle.branch")
            }
          Button { repository.delete(branch: branch) }
            label: {
              Text("Delete Branch")
              Image(systemName: "trash")
            }
        }
      }
    } label: {
      HStack {
        Text(label)
        Spacer()
        if isExpanded {
          Button {
            repository.load()
          } label: { Image(systemName: "arrow.counterclockwise.icloud") }
        }
      }
    }
  }
}

struct BranchRepositoryView: View {
  @EnvironmentObject var repository: Model.Repository
  @State private var name = ""
  
  public var callback: (() -> ())? = nil
  
  var body: some View {
    TextField("Branch Name", text: $name)
    HStack {
      Button { callback?() }
        label: { Text("Cancel") }
      Spacer()
      Button {
        Commands.Branch.create(name: name, on: repository) { _ in callback?() }
      }
      label: { Text("Create") }
    }
  }
}

struct BranchListView_Previews: PreviewProvider {
  static var previews: some View {
    BranchListView(branches: [], label: "Test")
  }
}
