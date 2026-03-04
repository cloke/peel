//
//  RootView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI
import Brew

struct Brew_RootView: View {
  var body: some View {
    NavigationStack {
      SidebarNavigationView()
        .toolbar {
          ToolSelectionToolbar()
          ChainActivityToolbar()
        }
    }
  }
}

#Preview {
  Brew_RootView()
}
