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
