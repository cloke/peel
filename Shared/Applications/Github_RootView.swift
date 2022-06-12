//
//  Github_RootView.swift
//  KitchenSync (macOS)
//
//  Created by Cory Loken on 7/14/21.
//

import SwiftUI
import Github

struct VerticalLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack {
      configuration.icon.font(.headline)
      configuration.title.font(.subheadline)
    }
  }
}

struct Github_RootView: View {
  var body: some View {
    VStack {
    Github.RootView()
      .frame(minWidth: 100)
    }
    .frame(idealHeight: 400)

      .toolbar {
#if os(macOS)
        ToggleSidebarToolbarItem(placement: .navigation)
        ToolSelectionToolbar()
#endif
        ToolbarItem(placement: .navigation) {
          Menu {
            Button {
              Github.reauthorize()
            } label: {
              Text("Logout")
              Image(systemName: "figure.wave")
            }
          } label: {
            Image(systemName: "gear")
          }
        }
      }
  }
}

struct Github_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Github_RootView()
  }
}
