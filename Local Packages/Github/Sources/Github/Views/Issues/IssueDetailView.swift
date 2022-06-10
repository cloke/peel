//
//  SwiftUIView.swift
//  
//
//  Created by Cory Loken on 10/3/21.
//

import SwiftUI
import MarkdownUI

struct IssueDetailView: View {
  let issue: Github.Issue
  
  var body: some View {
    ScrollView {
      Markdown(Document(stringLiteral: issue.body ?? ""))
    }
  }
}

//struct IssueDetailView_Previews: PreviewProvider {
//  static var previews: some View {
//    IssueDetailView(issue: Github.Issue())
//  }
//}
