//
//  SwiftUIView.swift
//  
//
//  Created by Cory Loken on 12/12/21.
//

import SwiftUI

public struct AvatarView: View {
  let url: URL?
  var minWidth: Double
  var maxWidth: Double
  var maxHeight: Double
  var alignment: Alignment
  
  public init(url: URL?, minWidth: Double = 0.0, maxWidth: Double = 30.0, maxHeight: Double = 30.0, alignment: Alignment = .center) {
    self.url = url
    self.minWidth = minWidth
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    self.alignment = alignment
  }
  
  public var body: some View {
    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
      switch phase {
      case .empty:
        ProgressView()
      case .success(let image):
        image
          .resizable()
          .scaledToFit()
          .transition(.opacity)
      case .failure(_):
        Image(systemName: "exclamationmark.icloud")
      @unknown default: EmptyView()
      }
    }
    .frame(minWidth: minWidth, maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
    .clipShape(Circle())
    .accessibilityLabel("User avatar")
  }
}

#Preview {
  AvatarView(url: URL(string: "https://avatars.githubusercontent.com/u/1"))
}
