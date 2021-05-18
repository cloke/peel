//
//  Git_BranchListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

public struct BranchListView: View {
  @State private var list = [Model.Branch]()
  @State private var upDown = ""
  
  @State public private(set) var selection: String?
  @State private var isShowing = false
  @State private var isExpanded = false
  
  public var label: String
  public var location: String = "-r"
  
  public init(label: String, location: String = "-r") {
    self.label = label
    self.location = location
  }
  
  public var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(list) { branch in
        NavigationLink(destination: HistoryListView(branch: branch.name), tag: branch.name, selection: self.$selection) {
          Text(branch.name)
            .fontWeight(branch.isActive ? .bold : .regular)
            .gesture(
              TapGesture(count: 1)
                .onEnded({ selection = branch.name })
            )
            .highPriorityGesture(
              TapGesture(count: 2)
                .onEnded({
                  selection = branch.name
                  Commands.checkout(branch: branch.name, from: ViewModel.shared.selectedRepository) { _ in
                    Commands.Branch.show(from: location, on: ViewModel.shared.selectedRepository) { list = $0 }
                  }
                })
            )
          Spacer()
          Button {
            Commands.push(branch: branch.name, to: ViewModel.shared.selectedRepository) { _ in
              Commands.Branch.show(from: location, on: ViewModel.shared.selectedRepository) { list = $0 }
            }
          } label: { Image(systemName: "square.and.arrow.up") }
          Text(upDown)
            .onAppear {
              Commands.revList(branchA: "origin/\(branch.name)", branchB: branch.name) {
                upDown = "(⇣\($0) / \($1) ⇡)"
              }
            }
        }
        .sheet(isPresented: $isShowing) {
          BranchRepositoryView() { [self] in
            isShowing = false
            Commands.Branch.show(from: location, on: ViewModel.shared.selectedRepository) { list = $0 }
          }
          .padding()
          .frame(width: 300, height: 100)
        }
        .contextMenu(ContextMenu(menuItems: {
          Button {
            isShowing = true
          }
          label: {
            Text("Create Branch")
            Image(systemName: "arrow.triangle.branch")
          }
        }))
      }
    } label: {
      HStack {
        Text(label)
        Spacer()
        if isExpanded {
          Button {
            Commands.Branch.show(from: location, on: ViewModel.shared.selectedRepository) { list = $0 }
          } label: { Image(systemName: "arrow.counterclockwise.icloud") }
        }
      }
    }
    .onChange(of: isExpanded, perform:  { value in
      if isExpanded == true {
        Commands.Branch.show(from: location, on: ViewModel.shared.selectedRepository) { list = $0 }
      }
    })
  }
}

struct BranchRepositoryView: View {
  @State private var name = ""
  
  public var callback: (() -> ())? = nil
  
  var body: some View {
    TextField("Branch Name", text: $name)
    HStack {
      Button { callback?() }
        label: { Text("Cancel") }
      Spacer()
      Button {
        Commands.Branch.create(name: name, on: ViewModel.shared.selectedRepository) { _ in callback?() }
      }
      label: { Text("Create") }
    }
  }
}

struct BranchListView_Previews: PreviewProvider {
  static var previews: some View {
    BranchListView(label: "Test")
  }
}
