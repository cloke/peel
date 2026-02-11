//
//  RootView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI
import Brew

struct Brew_RootView: View {
  @State private var showActivity = false
  
  var body: some View {
    NavigationStack {
      SidebarNavigationView()
        .toolbar {
          ToolSelectionToolbar()
          ToolbarItem(placement: .primaryAction) {
            Button {
              showActivity.toggle()
            } label: {
              Label("Activity", systemImage: "chart.bar.fill")
            }
            .help("Homebrew Activity Charts")
          }
        }
        .sheet(isPresented: $showActivity) {
          BrewActivityView()
            .frame(minWidth: 550, minHeight: 500)
        }
    }
  }
}

#Preview {
  Brew_RootView()
}
