//
//  CreateWorktreeView.swift
//  Git
//
//  Created by Copilot on 1/7/26.
//

import SwiftUI

#if os(macOS)
public struct CreateWorktreeView: View {
  @Environment(\.dismiss) private var dismiss
  
  let repository: Model.Repository
  let onCreated: () -> Void
  
  @State private var worktreePath = ""
  @State private var selectedBranch = ""
  @State private var createNewBranch = false
  @State private var newBranchName = ""
  @State private var branches: [Model.Branch] = []
  @State private var isLoading = false
  @State private var errorMessage: String?
  
  public init(repository: Model.Repository, onCreated: @escaping () -> Void) {
    self.repository = repository
    self.onCreated = onCreated
  }
  
  public var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Create Worktree")
          .font(.headline)
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding()
      
      Divider()
      
      // Form
      Form {
        Section {
          HStack {
            TextField("Worktree Path", text: $worktreePath)
              .textFieldStyle(.roundedBorder)
            
            Button("Browse...") {
              selectFolder()
            }
          }
          
          Text("Path where the new worktree will be created")
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
          Text("Location")
        }
        
        Section {
          Toggle("Create new branch", isOn: $createNewBranch)
          
          if createNewBranch {
            TextField("New branch name", text: $newBranchName)
              .textFieldStyle(.roundedBorder)
            
            Picker("Start from", selection: $selectedBranch) {
              Text("HEAD").tag("")
              ForEach(branches) { branch in
                Text(branch.name).tag(branch.name)
              }
            }
          } else {
            Picker("Branch", selection: $selectedBranch) {
              ForEach(branches) { branch in
                Text(branch.name).tag(branch.name)
              }
            }
          }
        } header: {
          Text("Branch")
        }
        
        if let error = errorMessage {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .frame(minHeight: 250)
      
      Divider()
      
      // Footer
      HStack {
        Spacer()
        
        Button("Create") {
          Task { await createWorktree() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid || isLoading)
      }
      .padding()
    }
    .frame(width: 450)
    .task {
      await loadBranches()
      // Set default path
      let repoURL = URL(fileURLWithPath: repository.path)
      let parentDir = repoURL.deletingLastPathComponent()
      worktreePath = parentDir.appendingPathComponent("worktree-new").path
    }
  }
  
  private var isValid: Bool {
    if worktreePath.isEmpty {
      return false
    }
    if createNewBranch {
      return !newBranchName.isEmpty
    } else {
      return !selectedBranch.isEmpty
    }
  }
  
  private func loadBranches() async {
    do {
      branches = try await Commands.Branch.list(from: .local, on: repository)
      if let firstBranch = branches.first {
        selectedBranch = firstBranch.name
      }
    } catch {
      errorMessage = "Failed to load branches: \(error.localizedDescription)"
    }
  }
  
  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose location for the new worktree"
    panel.prompt = "Select"
    
    // Start in parent directory of repo
    let repoURL = URL(fileURLWithPath: repository.path)
    panel.directoryURL = repoURL.deletingLastPathComponent()
    
    if panel.runModal() == .OK, let url = panel.url {
      worktreePath = url.path
    }
  }
  
  private func createWorktree() async {
    isLoading = true
    errorMessage = nil
    
    do {
      if createNewBranch {
        try await Commands.Worktree.addWithNewBranch(
          path: worktreePath,
          newBranch: newBranchName,
          startPoint: selectedBranch.isEmpty ? nil : selectedBranch,
          on: repository
        )
      } else {
        try await Commands.Worktree.add(
          path: worktreePath,
          branch: selectedBranch,
          on: repository
        )
      }
      
      onCreated()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
    
    isLoading = false
  }
}

#Preview {
  CreateWorktreeView(
    repository: Model.Repository(name: "test", path: "/tmp/test"),
    onCreated: {}
  )
}
#endif
