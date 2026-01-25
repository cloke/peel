//
//  ButtonHelpers.swift
//  PeelUI
//
//  Created on 1/24/26.
//

import SwiftUI

// MARK: - Button Components

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

public struct SecondaryActionButton<Label: View>: View {
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
    .buttonStyle(.bordered)
  }
}

public struct IconActionButton: View {
  private let systemImage: String
  private let action: () -> Void
  private let help: String?

  public init(
    systemImage: String,
    help: String? = nil,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.help = help
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
    }
    .buttonStyle(.borderless)
    .help(help ?? "")
  }
}

// MARK: - Button Styles

/// A subtle button style for less prominent actions
public struct SubtleButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(configuration.isPressed ? .primary : .secondary)
      .opacity(configuration.isPressed ? 0.7 : 1.0)
  }
}

/// A pill-shaped button style often used for tags or filter chips
public struct PillButtonStyle: ButtonStyle {
  let isSelected: Bool

  public init(isSelected: Bool = false) {
    self.isSelected = isSelected
  }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
      .foregroundStyle(isSelected ? .white : .primary)
      .clipShape(Capsule())
      .opacity(configuration.isPressed ? 0.7 : 1.0)
  }
}

/// A card-style button with border and subtle background
public struct CardButtonStyle: ButtonStyle {
  let isSelected: Bool

  public init(isSelected: Bool = false) {
    self.isSelected = isSelected
  }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding()
      .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
      )
      .cornerRadius(8)
      .opacity(configuration.isPressed ? 0.8 : 1.0)
  }
}

// MARK: - Button Style Extensions

public extension ButtonStyle where Self == SubtleButtonStyle {
  static var subtle: SubtleButtonStyle { SubtleButtonStyle() }
}

public extension ButtonStyle where Self == PillButtonStyle {
  static func pill(isSelected: Bool = false) -> PillButtonStyle {
    PillButtonStyle(isSelected: isSelected)
  }
}

public extension ButtonStyle where Self == CardButtonStyle {
  static func card(isSelected: Bool = false) -> CardButtonStyle {
    CardButtonStyle(isSelected: isSelected)
  }
}

// MARK: - Async Button

/// A button that shows a loading indicator during async operations
public struct AsyncActionButton<Label: View>: View {
  private let action: () async -> Void
  private let label: () -> Label
  @State private var isLoading = false

  public init(
    action: @escaping () async -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.action = action
    self.label = label
  }

  public var body: some View {
    Button {
      guard !isLoading else { return }
      isLoading = true
      Task {
        await action()
        isLoading = false
      }
    } label: {
      if isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
      } else {
        label()
      }
    }
    .disabled(isLoading)  }
}