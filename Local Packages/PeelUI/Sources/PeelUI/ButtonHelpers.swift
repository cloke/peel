//
//  ButtonHelpers.swift
//  PeelUI
//
//  Created on 1/24/26.
//

import SwiftUI

public struct DestructiveActionButton<Label: View>: View {
  private let action: () -> Void
  private let label: () -> Label

  public init(
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.action = action
    self.label = label
  }

  public var body: some View {
    Button(role: .destructive) {
      action()
    } label: {
      label()
    }
    .tint(.red)
  }
}

public struct PrimaryActionButton<Label: View>: View {
  private let action: () -> Void
  private let label: () -> Label

  public init(
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.action = action
    self.label = label
  }

  public var body: some View {
    Button {
      action()
    } label: {
      label()
    }
    .buttonStyle(.borderedProminent)
  }
}
