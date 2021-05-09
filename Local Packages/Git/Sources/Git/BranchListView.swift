//
//  Git_BranchListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

public struct BranchListView: View {
  @State private var list = [Branch]()
  @State private var upDown = ""
  
  @State public private(set) var selection: String?
  @State private var isShowing = false
  
  public var label: String
  public var location: String = "-r"
  
  public init(label: String, location: String = "-r") {
    self.label = label
    self.location = location
  }
  
  public var body: some View {
    DisclosureGroup {
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
                  ViewModel.shared.checkout(branch: branch.name) { _ in
                    ViewModel.shared.showBranches(from: location) { list = $0 }
                  }
                })
            )
          Spacer()
          Button {
            ViewModel.shared.push(branch: branch.name) { _ in
              ViewModel.shared.showBranches(from: location) { list = $0 }
            }
          } label: { Image(systemName: "square.and.arrow.up") }
          Text(upDown)
            .onAppear {
              ViewModel.shared.revList(branchA: "origin/\(branch.name)", branchB: branch.name) {
                upDown = "(⇣\($0) / \($1) ⇡)"
              }
            }
        }
        .sheet(isPresented: $isShowing) {
          BranchRepositoryView() { [self] in
            isShowing = false
            ViewModel.shared.showBranches(from: location) { list = $0 }
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
        Button {
          ViewModel.shared.showBranches(from: location) { list = $0 }
        } label: { Image(systemName: "arrow.counterclockwise.icloud") }
      }
    }
  }
}

struct BranchRepositoryView: View {
  @State private var name = ""
  
  public var callack: (() -> ())? = nil
  
//  init(callack: (() -> ())? = nil) {
//    self.callack = callack
//  }
  
  var body: some View {
    TextField("Branch Name", text: $name)
    HStack {
      Button { callack?() }
        label: { Text("Cancel") }
      Spacer()
      Button {
        ViewModel.shared.branch(name: name) { _ in callack?() }
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
