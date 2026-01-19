//
//  ActionListView.swift
//  SwiftUIView
//
//  Created by Cory Loken on 8/1/21.
//

import SwiftUI

public struct ActionConclusionView: View {
  let conclusion: String
  
  public init(conclusion: String) {
    self.conclusion = conclusion
  }
  
  public var body: some View {
    Group {
      switch conclusion {
      case "success":
        Image(systemName: "checkmark.circle")
          .foregroundColor(.green)
      case "failure":
        Image(systemName: "xmark.circle")
          .foregroundColor(.red)
      case "cancelled":
        Image(systemName: "nosign")
          .foregroundColor(.yellow)
      default:
        Image(systemName: "questionmark.circle")
      }
    }
    .help(conclusion)
  }
}

struct ActionsView: View {
  public let repository: Github.Repository
  
  @State private var isLoading = true
  @State private var actions = [Github.Action]()
  
  var body: some View {
    VStack {
      if isLoading {
        ProgressView()
      } else if !actions.isEmpty {
        ActionsListView(repository: repository, actions: actions)
      } else {
        Text("No Actions Found")
      }
    }
    .task(id: repository.id) {
      isLoading = true
      actions = []
      do {
        for workflow in try await Github.workflows(from: repository) {
          let actions = try await Github.runs(from: workflow, repository: repository)
          self.actions.append(contentsOf: actions)
        }
      } catch {
        print(error)
      }
      isLoading = false
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
  let repository: Github.Repository
  let actions: [Github.Action]
  
  var body: some View {
    List(actions.sorted(by: { $0.updated_at > $1.updated_at })) { action in
      VStack {
        NavigationLink(destination: ActionDetailView(action: action)) {
          ActionsListItemView(action: action)
        }
        Divider()
      }
    }
  }
}

//struct ActionsListView_Previews: PreviewProvider {
//  static var previews: some View {
////    ActionsListView()
//  }
//}

