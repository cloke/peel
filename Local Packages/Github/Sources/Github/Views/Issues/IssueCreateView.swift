//
//  IssueCreateView.swift
//  IssueCreateView
//
//  Created by Cory Loken on 7/20/21.
//  Modernized to @Observable on 1/5/26
//

import SwiftUI

struct IssueCreateView: View {
  @Binding var showSheet: Bool
  let repository: Github.Repository
  
  @Environment(Github.ViewModel.self) private var viewModel
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
        Task {
          do {
            _ = try await Github.createIssue(for: repository, title: title, body: issueBody, owner: owner)
            showSheet = false
          } catch {
            print("Something happened, if only I had a way to tell the user!!")
          }
        }
      }
    }
    .padding()
    .frame(minWidth: 200, idealWidth: 200, minHeight: 300, idealHeight: 300)
  }
}
