//
//  SwiftUIView.swift
//  
//
//  Created by Cory Loken on 12/12/21.
//

import SwiftUI

struct AvatarView: View {
  let url: URL?
  var minWidth = 0.0
  var maxWidth = 30.0
  var maxHeight = 30.0
  var alignment: Alignment = .center
  
  var body: some View {
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
  }
}

struct AvatarView_Previews: PreviewProvider {
  static var previews: some View {
    AvatarView(url: URL(string: "test"))
  }
}
