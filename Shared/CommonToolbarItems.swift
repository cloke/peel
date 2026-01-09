//
//  CommonToolbarItems.swift
//  KitchenSync
//
//  Created by Cory Loken on 1/1/21.
//  Updated for better UX on 1/7/26
//

import SwiftUI

struct ToolSelectionToolbar: ToolbarContent {
  @AppStorage(wrappedValue: .brew, "current-tool") private var currentTool: CurrentTool

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      Picker("Tool", selection: $currentTool) {
        Label("Agents", systemImage: "cpu")
          .labelStyle(.titleAndIcon)
          .tag(CurrentTool.agents)
        Label("Brew", systemImage: "mug")
          .labelStyle(.titleAndIcon)
          .tag(CurrentTool.brew)
        Label("Git", systemImage: "arrow.triangle.branch")
          .labelStyle(.titleAndIcon)
          .tag(CurrentTool.git)
        Label("GitHub", systemImage: "person.2")
          .labelStyle(.titleAndIcon)
          .tag(CurrentTool.github)
      }
      .pickerStyle(.segmented)
      .help("Switch between tools")
    }
  }
}

struct ToggleSidebarToolbarItem: ToolbarContent {
  let placement: ToolbarItemPlacement
  
  func toggleSidebar() {
    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
  }
  
  var body: some ToolbarContent {
    ToolbarItem(placement: placement) {
      Button { toggleSidebar() }
        label: { Image(systemName: "sidebar.left") }
        .help(Text("Toggle Sidebar"))
    }
  }
}
