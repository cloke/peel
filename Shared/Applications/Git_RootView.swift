//
//  GitRootView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/20/20.
//  Fixed deprecated Alert on 1/7/26
//

import SwiftUI
import Git

struct Git_RootView: View {
  @State private var viewModel: ViewModel = .shared
  
  @State private var repoNotFoundError = false
  @State public var isCloning = false

  var body: some View {
    Group {
      if viewModel.selectedRepository.name == "N/A" {
        ContentUnavailableView {
          Label("No Repository", systemImage: "folder")
        } description: {
          Text("Open a git repository to get started")
        } actions: {
          Button("Open Repository") {
            viewModel.addRepository() {
              repoNotFoundError = true
            }
          }
          .buttonStyle(.borderedProminent)
        }
      } else {
        GitRootView(repository: viewModel.selectedRepository)
      }
    }
    .toolbar {
      ToolSelectionToolbar()
      RepositoriesMenuToolbarItem(repositories: viewModel.repositories, selectedRepository: $viewModel.selectedRepository)
      ToggleSidebarToolbarItem(placement: .navigation)
      
      ToolbarItem(placement: .navigation) {
        Button {
          viewModel.addRepository() {
            repoNotFoundError = true
          }
        } label : { Image(systemName: "folder.badge.plus") }
        .help(Text("Open Repository"))
      }
      ToolbarItem(placement: .navigation){
        Button {
          isCloning = true
        } label: { Image(systemName: "folder.badge.gear") }
        .help("Clone Repository")
      }
    }
    .alert("Repository Not Found", isPresented: $repoNotFoundError) {
      Button("OK", role: .cancel) { }
    } message: {
      Text("A git repository could not be found at that location.")
    }
    .sheet(isPresented: $isCloning) {
      CloneRepositoryView(isCloning: $isCloning)
        .padding()
        .frame(width: 300, height: 100)
    }
  }
}


struct Git_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Git_RootView()
  }
}
