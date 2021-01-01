//
//  GitRootView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI

extension Git {
  struct ColumnOneView: View {
    let repository: Repository
    
    var body: some View {
      VStack {
        List {
          LocalChangesListView(repository: repository)
          BranchListView(label: "Local Branches", location: "-l")
          BranchListView(label: "Remove Branches", location: "-r")
        }
        Spacer()
      }
      .frame(minWidth: 100)
    }
  }
}

extension Git {
  struct RepositorySelectionToolbarItem: ToolbarContent {
    let repositories: [Repository]
    @Binding var selectedRepository: Repository
    
    var body: some ToolbarContent {
      ToolbarItem {
        Menu(selectedRepository.name) {
          ForEach(repositories) { repository in
            Button(repository.name) {
              selectedRepository = repository
            }
          }
        }
      }
    }
  }
}

struct ToggleSidebarToolbarItem: ToolbarContent {
  let placement: ToolbarItemPlacement
  
  func toggleSidebar() {
    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
  }
  
  var body: some ToolbarContent {
    ToolbarItem(placement: placement) {
      Button { toggleSidebar() }
        label: { Image(systemName: "sidebar.left") }
        .help(Text("Toggle Sidebar"))
    }
  }
}

extension Git {
  struct RootView: View {
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
          RepositorySelectionToolbarItem(repositories: viewModel.repositories, selectedRepository: $viewModel.selectedRepository)
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
}

struct Git_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Git.RootView()
  }
}
