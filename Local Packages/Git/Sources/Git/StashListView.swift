//
//  StashListView.swift
//  
//
//  Created by Cory Loken on 2/22/21.
//

import SwiftUI

struct StashListView: View {
  public let repository: Model.Repository
  @State private var stashes = [String]()
  @State private var isExpanded = false
  
  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      List(stashes, id: \.self) {
        Text($0)
      }
      .onChange(of: repository.id, perform: { value in
        Commands.Stash.list(on: repository) { self.stashes = $0 }
      })
      .onChange(of: isExpanded, perform:  { value in
        if isExpanded == true {
          Commands.Stash.list(on: repository) { self.stashes = $0 }
        }
      })
    } label: {
      HStack {
        Text("Stash")
        Spacer()
        Button {
          Commands.Stash.list(on: repository) { self.stashes = $0 }
        } label: {
          Image(systemName: "arrow.counterclockwise.icloud")
        }
      }
    }
  }
}
