//
//  ToolbarItems.swift
//  PeelUI
//
//  Created on 1/24/26.
//

import SwiftUI

public struct RefreshToolbarItem: ToolbarContent {
  private let placement: ToolbarItemPlacement
  private let label: String
  private let action: () -> Void
  private let accessibilityIdentifier: String

  public init(
    placement: ToolbarItemPlacement = .automatic,
    label: String = "Refresh",
    accessibilityIdentifier: String = "common.toolbar.refresh",
    action: @escaping () -> Void
  ) {
    self.placement = placement
    self.label = label
    self.accessibilityIdentifier = accessibilityIdentifier
    self.action = action
  }

  public var body: some ToolbarContent {
    ToolbarItem(placement: placement) {
      Button {
        action()
      } label: {
        Label(label, systemImage: "arrow.clockwise")
          .labelStyle(.iconOnly)
      }
      .help(label)
      .accessibilityLabel(label)
      .accessibilityIdentifier(accessibilityIdentifier)
    }
  }
}
