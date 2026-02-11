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
    HStack {
      AsyncImage(url: URL(string: me.avatar_url)) { image in
        image
          .resizable()
          .scaledToFit()
          .clipped()
          .clipShape(Circle())
      } placeholder: {
        ProgressView()
      }
      .frame(minWidth: 0, maxWidth: 30, maxHeight: 30, alignment: .center)
      Text(me.name ?? "")
      Spacer()
    }
  }
}

//struct ProfileNameView_Previews: PreviewProvider {
//    static var previews: some View {
//      ProfileNameView()
//    }
//}
