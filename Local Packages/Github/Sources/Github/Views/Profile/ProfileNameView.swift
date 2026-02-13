//
//  ProfileNameView.swift
//  
//
//  Created by Cory Loken on 10/4/21.
//

import SwiftUI

public struct ProfileNameView: View {
  let me: Github.User
  
  public init(me: Github.User) {
    self.me = me
  }
  
  public var body: some View {
    HStack(spacing: 10) {
      AsyncImage(url: URL(string: me.avatar_url)) { image in
        image
          .resizable()
          .scaledToFill()
          .clipShape(Circle())
      } placeholder: {
        Circle()
          .fill(.quaternary)
          .overlay {
            Image(systemName: "person.fill")
              .foregroundStyle(.tertiary)
              .font(.caption)
          }
      }
      .frame(width: 28, height: 28)
      
      VStack(alignment: .leading, spacing: 1) {
        Text(me.name ?? me.login ?? "")
          .font(.callout)
          .fontWeight(.medium)
        if let login = me.login, login != me.name {
          Text("@\(login)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      
      Spacer()
      
      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}
