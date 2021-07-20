//
//  CommitsListItemView.swift
//  CommitsListItemView
//
//  Created by Cory Loken on 7/18/21.
//

import SwiftUI

struct CommitsListItemView: View {
  let commit: Github.Commit
  
  var body: some View {
    VStack(alignment: .leading) {
      HStack(alignment: .top) {
        Text(commit.author?.login ?? "Unknown Author")
          .font(.headline)
        Spacer()
        Text(commit.commit.author.dateFormated)
          .font(.subheadline)
      }
      
      Text(commit.commit.message)
        .padding()
    }
  }
}

struct CommitsListItemView_Previews: PreviewProvider {
  static let decoder = JSONDecoder()
  static let commit = try! decoder.decode(Github.Commit.self, from: Fixtures.commit)
  static var previews: some View {
    CommitsListItemView(commit: commit)
  }
}
