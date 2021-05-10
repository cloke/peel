//
//  StashListView.swift
//  
//
//  Created by Cory Loken on 2/22/21.
//

import SwiftUI

struct StashListView: View {
  public let repository: Repository
  @State private var stashes = [String]()
  @State private var isExpanded = false
  
  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      List(stashes, id: \.self) {
        Text($0)
      }
      .onChange(of: repository.id, perform: { value in
        ViewModel.Stash.list() { self.stashes = $0 }
      })
      .onChange(of: isExpanded, perform:  { value in
        if isExpanded == true {
          ViewModel.Stash.list() { self.stashes = $0 }
        }
      })
    } label: {
      HStack {
        Text("Stash")
        Spacer()
        Button {
          ViewModel.Stash.list() { self.stashes = $0 }
        } label: {
          Image(systemName: "arrow.counterclockwise.icloud")
        }
      }
    }
  }
}
