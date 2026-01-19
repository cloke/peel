//
//  Chip.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

struct Chip: View {
  enum Style: Equatable {
    case pill
    case rounded(CGFloat)
  }

  let text: String
  var systemImage: String? = nil
  var style: Style = .pill
  var font: Font = .caption2
  var fontWeight: Font.Weight? = .medium
  var foreground: Color = .secondary
  var background: Color = Color.secondary.opacity(0.15)
  var horizontalPadding: CGFloat = 6
  var verticalPadding: CGFloat = 2
  var lineLimit: Int? = 1

  private var cornerRadius: CGFloat {
    switch style {
    case .pill:
      return 999
    case .rounded(let radius):
      return radius
    }
  }

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
        .lineLimit(lineLimit)
    }
    .font(font)
    .fontWeight(fontWeight)
    .foregroundStyle(foreground)
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .background(background, in: RoundedRectangle(cornerRadius: cornerRadius))
  }
}
