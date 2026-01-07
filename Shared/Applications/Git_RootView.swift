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
    VStack {
      if viewModel.selectedRepository.name == "N/A" {
        Text("No repository selected")
      } else {
        GitRootView(repository: viewModel.selectedRepository)
          .frame(minWidth: 100)
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
          // TODO: add view go get remote repo url. Then show folder select for destination
        } label: { Image(systemName: "folder.badge.gear") }
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

#Preview {
  Git_RootView()
}
