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

struct IssuesLisView: View {
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
        List(issues) { issue in
          Text(issue.title)
          HStack {
            ForEach(issue.labels) { label in
              Text(label.name)
                .background(Color.init(hex: label.color))
            }
          }
        }
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
