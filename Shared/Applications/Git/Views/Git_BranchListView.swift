//
//  Git_BranchListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

extension Git {
  struct BranchListView: View {
    @State private var list = [Branch]()
    @State var selection: String?
    
    var label: String
    var location: String = "-r"
    
    var body: some View {
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
            Button {
              ViewModel.shared.push(branch: branch.name) {
                ViewModel.shared.showBranches(from: location) {
                  list = $0
                }
              }
            } label: { Image(systemName: "square.and.arrow.up") }
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
}

struct Git_BranchListView_Previews: PreviewProvider {
  static var previews: some View {
    Git.BranchListView(label: "Test")
  }
}
