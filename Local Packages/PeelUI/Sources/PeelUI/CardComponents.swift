//
//  CardComponents.swift
//  PeelUI
//
//  Reusable card-based UI components for consistent styling across Peel
//  Created on 1/30/26
//

import SwiftUI

// MARK: - Section Card

/// A card component with a title and content area
/// Used for settings, dashboards, and grouped content
///
/// Example:
/// ```swift
/// SectionCard("Database") {
///   Text("Content here")
/// }
///
/// SectionCard {
///   Text("Content without title")
/// } header: {
///   HStack {
///     Text("Custom Header")
///     Spacer()
///     StatusPill(text: "Ready", style: .success)
///   }
/// }
/// ```
public struct SectionCard<Content: View, Header: View>: View {
  private let header: Header
  private let content: Content
  
  public init(
    @ViewBuilder content: () -> Content,
    @ViewBuilder header: () -> Header
  ) {
    self.header = header()
    self.content = content()
  }
  
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .font(.headline)
        .padding(.bottom, 12)
      
      VStack(alignment: .leading, spacing: 14) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

// Convenience initializer for simple string title
extension SectionCard where Header == Text {
  public init(_ title: String, @ViewBuilder content: () -> Content) {
    self.header = Text(title)
    self.content = content()
  }
}

// Convenience initializer for headerless card
extension SectionCard where Header == EmptyView {
  public init(@ViewBuilder content: () -> Content) {
    self.header = EmptyView()
    self.content = content()
  }
}

// MARK: - Stat Card

/// A compact card for displaying a single statistic with icon and label
///
/// Example:
/// ```swift
/// HStack(spacing: 12) {
///   StatCard(value: "4,529", label: "Files", icon: "doc.text")
///   StatCard(value: "11,209", label: "Chunks", icon: "square.grid.3x3")
/// }
/// ```
public struct StatCard: View {
  public let value: String
  public let label: String
  public let icon: String
  
  public init(value: String, label: String, icon: String) {
    self.value = value
    self.label = label
    self.icon = icon
  }
  
  public var body: some View {
    VStack(spacing: 4) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.title3, design: .rounded, weight: .semibold))
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Status Pill

/// A small pill-shaped status indicator
///
/// Example:
/// ```swift
/// StatusPill(text: "Running", style: .success)
/// StatusPill(text: "Warning", style: .warning)
/// StatusPill(text: "Stopped", style: .neutral)
/// ```
public struct StatusPill: View {
  public enum Style {
    case success
    case warning
    case error
    case neutral
  }
  
  public let text: String
  public let style: Style
  
  public init(text: String, style: Style) {
    self.text = text
    self.style = style
  }
  
  public var body: some View {
    Text(text)
      .font(.caption)
      .fontWeight(.semibold)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(backgroundColor)
      .foregroundStyle(foregroundColor)
      .clipShape(Capsule())
  }
  
  private var backgroundColor: Color {
    switch style {
    case .success: Color.green.opacity(0.2)
    case .warning: Color.orange.opacity(0.2)
    case .error: Color.red.opacity(0.2)
    case .neutral: Color.gray.opacity(0.2)
    }
  }
  
  private var foregroundColor: Color {
    switch style {
    case .success: .green
    case .warning: .orange
    case .error: .red
    case .neutral: .secondary
    }
  }
}

// MARK: - Memory Bar

/// A horizontal progress bar for displaying memory/resource usage
///
/// Example:
/// ```swift
/// MemoryBar(current: 8.5, total: 24.0)
/// ```
public struct MemoryBar: View {
  public let current: Double
  public let total: Double
  
  public init(current: Double, total: Double) {
    self.current = current
    self.total = total
  }
  
  private var percentage: Double {
    guard total > 0 else { return 0 }
    return min(current / total, 1.0)
  }
  
  private var color: Color {
    if percentage > 0.8 { return .red }
    if percentage > 0.6 { return .orange }
    return .green
  }
  
  public var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
          .fill(.fill.quaternary)
        RoundedRectangle(cornerRadius: 2)
          .fill(color)
          .frame(width: geo.size.width * percentage)
      }
    }
    .frame(width: 60, height: 6)
  }
}

// MARK: - Settings Row Helpers

/// A labeled row for settings with consistent styling
///
/// Example:
/// ```swift
/// SettingsRow("Port") {
///   TextField("", text: $port)
///     .frame(width: 80)
/// }
/// ```
public struct SettingsRow<Content: View>: View {
  public let label: String
  public let content: Content
  
  public init(_ label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }
  
  public var body: some View {
    HStack {
      Text(label)
      Spacer()
      content
    }
  }
}
