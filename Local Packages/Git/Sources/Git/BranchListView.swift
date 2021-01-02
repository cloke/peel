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
                .onEnded({
                  selection = branch.name
                })
            )
            .highPriorityGesture(
              TapGesture(count: 2)
                .onEnded({
                  selection = branch.name
                  ViewModel.shared.checkout(branch: branch.name) {
                    ViewModel.shared.showBranches(from: location) {
                      list = $0
                    }
                  }
                })
            )
          Spacer()
          Button {
            ViewModel.shared.push(branch: branch.name) {
              ViewModel.shared.showBranches(from: location) {
                list = $0
              }
            }
          } label: { Image(systemName: "square.and.arrow.up") }
          Text(upDown)
            .onAppear {
              ViewModel.shared.revList(branchA: "origin/\(branch.name)", branchB: branch.name) {
                upDown = "(⇣\($0) / \($1) ⇡)"
              }
            }
        }
      }
    } label: {
      HStack {
        Text(label)
        Spacer()
        Button {
          ViewModel.shared.showBranches(from: location) {
            list = $0
          }
        } label: {
          Image(systemName: "arrow.counterclockwise.icloud")
        }
      }
    }
  }
}

struct BranchListView_Previews: PreviewProvider {
  static var previews: some View {
    BranchListView(label: "Test")
  }
}
