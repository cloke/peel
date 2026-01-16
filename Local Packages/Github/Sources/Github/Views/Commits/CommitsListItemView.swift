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
      HStack(alignment: .bottom) {
        Text(commit.author?.login ?? "Unknown Author")
          .font(.headline)
        Spacer()
        Text(commit.commit.author.dateFormatted)
          .font(.subheadline)
      }
      
      Text(commit.commit.message)
        .padding(.vertical, 5)
    }
  }
}

#Preview {
  let decoder = JSONDecoder()
  let commit = try! decoder.decode(Github.Commit.self, from: Fixtures.commit)
  return CommitsListItemView(commit: commit)
    .frame(width: 200)
}
