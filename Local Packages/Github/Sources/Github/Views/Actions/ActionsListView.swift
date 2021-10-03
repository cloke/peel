//
//  ActionListView.swift
//  SwiftUIView
//
//  Created by Cory Loken on 8/1/21.
//

import SwiftUI

struct ActionsListItemView: View {
  let action: Github.Action
  
  var body: some View {
    VStack {
      HStack {
        if action.status == "in_progress" {
          ProgressView()
            .scaleEffect(0.5)
        } else {
          ActionConclusionView(conclusion: action.conclusion ?? "")
        }
        Text("#\(action.run_number)")
        Text(action.head_commit.message.components(separatedBy: "\n\n").first ?? "")
        Spacer()
        Text(action.updatedAtFormatted)
      }
      HStack {
        Text(action.repository.name)
        Text(action.name)
        Spacer()
      }
    }
  }
}

struct ActionsListView: View {
  public let repository: Github.Repository
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var actions = [Github.Action]()
  
  var body: some View {
    Group {
#if os(macOS)
      NavigationView {
        List {
          ForEach(actions.sorted(by: { $0.updated_at > $1.updated_at })) { action in
            NavigationLink(destination: ActionDetailView(action: action)) {
              ActionsListItemView(action: action)
            }
          }
        }
      }
#else
      List {
        ForEach(actions.sorted(by: { $0.updated_at > $1.updated_at })) { action in
          NavigationLink(destination: ActionDetailView(action: action)) {
            ActionsListItemView(action: action)
          }
        }
      }
#endif
    }
    .onAppear {
      Github.workflows(from: repository, success: { workflows in
        for workflow in workflows {
          Github.runs(from: workflow, repository: repository, success: { actions in
            self.actions.append(contentsOf: actions)
          })
        }
      })
      
    }
  }
}

//struct ActionsListView_Previews: PreviewProvider {
//  static var previews: some View {
////    ActionsListView()
//  }
//}

