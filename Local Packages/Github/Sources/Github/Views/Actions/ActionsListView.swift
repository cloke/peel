//
//  ActionListView.swift
//  SwiftUIView
//
//  Created by Cory Loken on 8/1/21.
//

import SwiftUI

struct ActionsView: View {
  public let repository: Github.Repository
  
  @State private var state: LoadingState = .loading
  @State private var actions = [Github.Action]()
  
  var body: some View {
    VStack {
      switch state {
      case .loading:
        ProgressView()
      case .loaded:
        ActionsListView(repository: repository, actions: actions)
      case .empty:
        Text("No Pull Requests Found")
      }
    }
    .onAppear {
      Github.workflows(from: repository, success: { workflows in
        for workflow in workflows {
          Github.runs(from: workflow, repository: repository, success: {
            self.actions.append(contentsOf: $0)
            state = $0.count == 0 ? .empty : .loaded
          })
        }
      })
    }
  }
}

struct ActionsListItemView: View {
  let action: Github.Action
  
  public var body: some View {
    VStack(alignment: .leading) {
      HStack(alignment: .top) {
        if action.status == "in_progress" {
          ProgressView()
            .scaleEffect(0.5)
        } else {
          ActionConclusionView(conclusion: action.conclusion ?? "")
        }
        Text("#\(action.run_number)")
        Text(action.updatedAtFormatted)
          .font(.subheadline)
      }
      Text(action.head_commit.message.components(separatedBy: "\n\n").first ?? "")
      Spacer()
      
      HStack {
        Text(action.repository.name)
        Text(action.name)
        Spacer()
      }
    }
  }
}

struct ActionsListView: View {
  @EnvironmentObject var viewModel: Github.ViewModel
  let repository: Github.Repository
  let actions: [Github.Action]
  
  var body: some View {
    Group {
#if os(macOS)
      NavigationView {
        List(actions.sorted(by: { $0.updated_at > $1.updated_at })) { action in
          VStack {
            NavigationLink(destination: ActionDetailView(action: action)) {
              ActionsListItemView(action: action)
            }
            Divider()
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
  }
}

//struct ActionsListView_Previews: PreviewProvider {
//  static var previews: some View {
////    ActionsListView()
//  }
//}

