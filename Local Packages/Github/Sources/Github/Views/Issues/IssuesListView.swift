//
//  IssuesLisView.swift
//  IssuesLisView
//
//  Created by Cory Loken on 7/19/21.
//

import SwiftUI

enum LoadingState {
  case loading, loaded, empty
}

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
  @State private var state: LoadingState = .loading
  @State private var isShowingCreateIssue = false {
    didSet {
      if isShowingCreateIssue == false {
        loadData()
      }
    }
  }
  
  func loadData() {
    state = .loading
    Github.issues(from: repository) {
      issues = $0
      state = $0.count == 0 ? .empty : .loaded
    } error: {
      print($0)
    }
  }
  
  var body: some View {
    VStack {
      Button {
        isShowingCreateIssue = true
      } label: { Label("Create Issue", systemImage: "plus") }
      switch state {
      case .loading:
        ProgressView()
      case .loaded:
#if os(macOS)
        NavigationView {
          List(issues) { issue in
            VStack {
              NavigationLink(destination: IssueDetailView(issue: issue)) {
                IssueListItemView(issue: issue)
              }
              Divider()
            }
          }
        }
#else
        List(issues) { issue in
          NavigationLink(destination: IssueDetailView(issue: issue)) {
            IssueListItemView(issue: issue)
          }
        }
        .navigationBarTitleDisplayMode(.inline)
#endif
      case .empty:
        Text("No issues found")
      }
    }
    .onAppear {
      loadData()
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
