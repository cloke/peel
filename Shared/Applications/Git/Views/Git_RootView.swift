//
//  GitRootView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI

extension Git {
  struct ColumnOneView: View {
    @Binding var repository: Repository
    
    var body: some View {
      VStack() {
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
  struct RootView: View {
    @StateObject private var viewModel: ViewModel = .shared
    @State private var repoNotFoundError = false
    @State private var selectedRepositoryLabel = "Repositories"
    @State private var selectedRepository = Repository(name: "N/A", path: ".")
    
    var body: some View {
      VStack {
        Menu(selectedRepositoryLabel) {
          ForEach(viewModel.repositories) { repository in
            Button(repository.name) {
              selectedRepository = repository
              selectedRepositoryLabel = repository.name
              viewModel.selectedRepository = repository
            }
          }
        }
        .onReceive(viewModel.$selectedRepository) {
          selectedRepositoryLabel = $0.name
        }
        VStack {
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
          Text("Open Repository")
        }
        .font(.caption)
        .padding()
        Divider()
        if selectedRepository.name == "N/A" {
          Text("No repo selected")
        } else {
          ColumnOneView(repository: self.$selectedRepository)
        }
      }
      .onReceive(viewModel.$selectedRepository) {
        selectedRepository = $0
      }
      .frame(idealHeight: 400)
    }
  }
}

struct Git_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Git.RootView()
  }
}
