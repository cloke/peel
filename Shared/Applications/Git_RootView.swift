//
//  GitRootView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI
import Git

struct Git_RootView: View {
  @StateObject private var viewModel: ViewModel = .shared
  @State private var repoNotFoundError = false
  
  var body: some View {
    VStack {
      VStack {
        if viewModel.selectedRepository.name == "N/A" {
          Text("No repo selected")
        } else {
          ColumnOneView(repository: viewModel.selectedRepository)
        }
      }
      .frame(idealHeight: 400)
      .toolbar {
        ToolSelectionToolbar()
        RepositoriesToolbarItem(repositories: viewModel.repositories, selectedRepository: $viewModel.selectedRepository)
        ToggleSidebarToolbarItem(placement: .navigation)
        
        ToolbarItem(placement: .navigation) {
          Button {
            viewModel.addRepository() {
              repoNotFoundError = true
            }
          } label : {
            Image(systemName: "folder.badge.plus")
          }
          .alert(isPresented: $repoNotFoundError) {
            Alert(
              title: Text("Repository Not Found!"),
              message: Text("A git repository could not be found."),
              dismissButton: .default(Text("Ok"))
            )
          }
          .help(Text("Open Repository"))
        }
      }
    }
  }
}

struct Git_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Git_RootView()
  }
}
