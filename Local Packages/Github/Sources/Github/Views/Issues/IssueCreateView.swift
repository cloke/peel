//
//  IssueCreateView.swift
//  IssueCreateView
//
//  Created by Cory Loken on 7/20/21.
//

import SwiftUI

struct IssueCreateView: View {
  @Binding var showSheet: Bool
  let repository: Github.Repository
  
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var title = ""
  @State private var issueBody = ""
  
  var body: some View {
    VStack {
      Text("Reported by \(viewModel.me?.login ?? "Unknown")")
      TextField("Title", text: $title)
      Text("Description")
      TextEditor(text: $issueBody)
      Button("Submit") {
        guard let owner = viewModel.me?.login else { return print("Tried to create an issue with no owner") }
        Github.createIssue(for: repository, title: title, body: issueBody, owner: owner, success: { _ in
          showSheet = false
        }, error: { _ in
          print("Something happened, if only I had a way to tell the user!!")
        })
      }
    }
    .padding()
    .frame(minWidth: 200, idealWidth: 200, minHeight: 300, idealHeight: 300)
  }
}
