//
//  CommonToolbarItems.swift
//  KitchenSink
//
//  Created by Cory Loken on 1/1/21.
//

import SwiftUI

struct ToolSelectionToolbar: ToolbarContent {
  @AppStorage(wrappedValue: .brew, "current-tool") private var currentTool: CurrentTool

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu(currentTool.rawValue.capitalized) {
        Button(CurrentTool.brew.rawValue.capitalized) { currentTool = .brew }
        Button(CurrentTool.git.rawValue.capitalized) { currentTool = .git }
      }
    }
  }
}

