//
//  StashListView.swift
//  
//
//  Created by Cory Loken on 2/22/21.
//

import SwiftUI

#if os(macOS)
struct StashListView: View {
  public let repository: Model.Repository
  @State private var stashes = [String]()
  @State private var isExpanded = false
  
  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      List(stashes, id: \.self) {
        Text($0)
      }
      .onChange(of: isExpanded, perform:  { value in
        if isExpanded == true {
          Task {
            self.stashes = try await Commands.Stash.list(on: repository)
          }
        }
      })
    } label: {
      HStack {
        Text("Stash")
        Spacer()
        if isExpanded {
          Button {
            Task {
              self.stashes = try await Commands.Stash.list(on: repository)
            }
          } label: {
            Image(systemName: "arrow.counterclockwise.icloud")
          }
        }
      }
    }
  }
}
#endif
