//
//  ProfileNameView.swift
//  
//
//  Created by Cory Loken on 10/4/21.
//

import SwiftUI

struct ProfileNameView: View {
  let me: Github.User
  
  var body: some View {
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
    }
  }
}

//struct ProfileNameView_Previews: PreviewProvider {
//    static var previews: some View {
//      ProfileNameView()
//    }
//}
