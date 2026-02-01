//
//  SectionLayout.swift
//  Peel
//
//  Created on 1/21/26.
//

import SwiftUI

enum LayoutSpacing {
  static let page: CGFloat = 20
  static let section: CGFloat = 16
  static let item: CGFloat = 10
  static let indent: CGFloat = 20
}

struct SectionHeader: View {
  enum Style {
    case primary
    case secondary
  }

  let title: String
  var style: Style = .primary

  init(_ title: String, style: Style = .primary) {
    self.title = title
    self.style = style
  }

  var body: some View {
    Text(title)
      .font(style == .primary ? .headline : .caption)
      .foregroundStyle(style == .primary ? .primary : .secondary)
  }
}

// MARK: - Tool Page Components

/// Standard page layout for tool views (PII Scrubber, Translation Validator, etc.)
/// Provides consistent scroll behavior and padding.
struct ToolPageLayout<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        content()
      }
      .padding(16)
    }
  }
}

/// Standard section container for tool views.
/// Wraps content in a GroupBox with headline title and consistent spacing.
struct ToolSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(.headline)
        content()
      }
    }
  }
}
