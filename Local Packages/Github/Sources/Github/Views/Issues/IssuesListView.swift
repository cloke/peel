//
//  IssuesLisView.swift
//  IssuesLisView
//
//  Created by Cory Loken on 7/19/21.
//

import SwiftUI
import PeelUI

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
  @State private var showingCreateIssue = false
  @State private var refreshID = UUID()
  
  var body: some View {
    AsyncContentView(
      load: { try await Github.issues(from: repository) },
      content: { issues in
        List(issues) { issue in
          NavigationLink(destination: IssueDetailView(issue: issue)) {
            IssueListItemView(issue: issue)
          }
        }
      },
      emptyView: { EmptyStateView("No Issues", systemImage: "list.bullet") }
    )
    .id(refreshID)
    .toolbar {
      Button {
        showingCreateIssue = true
      } label: {
        Label("Create Issue", systemImage: "plus")
      }
    }
    .sheet(isPresented: $showingCreateIssue) {
      IssueCreateView(showSheet: $showingCreateIssue, repository: repository)
    }
    .onChange(of: showingCreateIssue) { _, isShowing in
      if !isShowing {
        refreshID = UUID()  // Trigger reload when sheet closes
      }
    }
  }
}
