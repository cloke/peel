//
//  CreateDetachedBranchSheet.swift
//  Git
//
//  Extracted from WorktreeListView.swift
//

import SwiftUI

#if os(macOS)
struct CreateDetachedBranchSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var branchName: String = ""
  let onCreate: (String) -> Void
  
  var body: some View {
    VStack(spacing: 16) {
      Text("Create Branch")
        .font(.headline)
      TextField("Branch name", text: $branchName)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 320)
      HStack {
        Button("Cancel") {
          dismiss()
        }
        Spacer()
        Button("Create") {
          onCreate(branchName)
          dismiss()
        }
        .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 420)
  }
}
#endif
