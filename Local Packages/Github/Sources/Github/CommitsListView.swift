//
//  CommitsListView.swift
//  CommitsListView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI

extension Github {
  struct CommitsListView: View {
    public let organization: String
    public let repository: Repository
    
    @EnvironmentObject var viewModel: ViewModel
    @State private var commits = [Github.Commit]()
    
    var body: some View {
      List(commits, id: \.sha) { commit in
        VStack {
          VStack {
            HStack(alignment: .top) {
              Text(commit.author?.login ?? "Unknown Login")
              Text(commit.commit.message)
              Spacer()
              
              Text(commit.commit.author.dateFormated)
            }
          }
          Divider()
        }
      }
      .onAppear {
        Github.commits(from: repository) {
          commits = $0
        } error: {
          print($0)
        }
      }
    }
  }
}
