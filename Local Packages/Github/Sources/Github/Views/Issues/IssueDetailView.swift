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
