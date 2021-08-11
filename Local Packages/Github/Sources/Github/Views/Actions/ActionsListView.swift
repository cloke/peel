//
//  ActionListView.swift
//  SwiftUIView
//
//  Created by Cory Loken on 8/1/21.
//

import SwiftUI

struct ActionsListView: View {
  public let repository: Github.Repository
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var actions = [Github.Action]()
  
  var body: some View {
    NavigationView {
      List(actions) { action in
        VStack {
        NavigationLink(destination: ActionDetailView(action: action)) {
          //            CommitsListItemView(commit: commit)
          //          }
          Text(action.name)
        }
        }
      }
      .onAppear {
        Github.actions(from: repository) {
          actions = $0.workflow_runs
        } error: {
          print($0)
        }
      }
    }
  }
}

//struct ActionsListView_Previews: PreviewProvider {
//  static var previews: some View {
////    ActionsListView()
//  }
//}

