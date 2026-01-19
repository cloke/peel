//
//  IssuesLisView.swift
//  IssuesLisView
//
//  Created by Cory Loken on 7/19/21.
//

import SwiftUI

struct IssueListItemView: View {
  let issue: Github.Issue
  
  var body: some View {
    Text(issue.title)
    HStack {
      ForEach(issue.labels) { label in
        Text(label.name)
          .background(Color.init(hex: label.color))
      }
    }
  }
}

struct IssuesListView: View {
  let repository: Github.Repository
  
  @State private var issues = [Github.Issue]()
  @State private var isLoading = true
  @State private var isShowingCreateIssue = false {
    didSet {
      if isShowingCreateIssue == false {
        Task {
          try? await loadData()
        }
      }
    }
  }
  
  func loadData() async throws {
    isLoading = true
    defer { isLoading = false }
    issues = try await Github.issues(from: repository)
  }
  
  var body: some View {
    VStack {
      Button {
        isShowingCreateIssue = true
      } label: { Label("Create Issue", systemImage: "plus") }
      if isLoading {
        ProgressView()
      } else if !issues.isEmpty {
        List(issues) { issue in
          VStack {
            NavigationLink(destination: IssueDetailView(issue: issue)) {
              IssueListItemView(issue: issue)
            }
            Divider()
          }
        }
      } else {
        Text("No issues found")
      }
    }
    .task(id: repository.id) {
      try? await loadData()
    }
    .sheet(isPresented: $isShowingCreateIssue, onDismiss: { isShowingCreateIssue = false }) {
      IssueCreateView(showSheet: $isShowingCreateIssue, repository: repository)
    }
  }
}

//struct IssuesLisView_Previews: PreviewProvider {
//  static var previews: some View {
//    Text("Hello, World!")
//  }
//}
