//
//  GitRootView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI

extension Git {
  struct FileListView: View {
    @ObservedObject private var viewModel = ViewModel()
    @State private var commitOrPath: String? = nil
    @State private var commitMessage: String = ""
    
    var body: some View {
      NavigationView {
        List {
          TextEditor(text: $commitMessage)
          Button("Commit Changes") {
            viewModel.commit(message: commitMessage) {
              viewModel.status()
            }
          }
          ForEach(viewModel.changes, id: \.self) { string in
            Text(string)
              .truncationMode(.head)
              .lineLimit(1)
              .clipped()
              .background(Color.green)
              .contentShape(Rectangle())
              
              .onTapGesture {
                var file = string.split(separator: " ")
                file.removeFirst()
                commitOrPath = file.joined(separator: "")
              }
          }
        }
        if commitOrPath != nil {
          DiffView(commitOrPath: commitOrPath!)
        }
      }
      .onAppear {
        viewModel.status()
      }
    }
  }
  
  struct LocalChangesListView: View {
    @ObservedObject private var viewModel = ViewModel()
    var repository: Repository
    
    var body: some View {
      NavigationLink(destination: FileListView()) {
        HStack {
          Text("Local Changes")
          Spacer()
          Button {
            viewModel.status()
          } label: {
            Image(systemName: "arrow.counterclockwise.icloud")
          }
        }
      }
    }
  }
  
  struct ColumnOneView: View {
    var repository: Repository
    
    var body: some View {
      VStack() {
        List {
          LocalChangesListView(repository: repository)
          BranchListView(repository: repository, label: "Local Branches", location: "-l")
          BranchListView(repository: repository, label: "Remove Branches", location: "-r")
        }
        Spacer()
      }
    }
  }
}

extension Git {
  struct RootView: View {
    @ObservedObject private var viewModel: ViewModel = .shared
    @State private var repoNotFoundError = false
    @State private var selectedRepositoryLabel = "Repositories"
    @State private var selectedRepository: Repository? = nil
    
    var body: some View {
      VStack {
        HStack {
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
          Spacer()
        }
        .font(.caption)
        .padding()
        Divider()
        if selectedRepository == nil {
          Text("No repo selected")
        } else {
          NavigationView {
            ColumnOneView(repository: selectedRepository!)
          }
        }
      }
      .onReceive(viewModel.$selectedRepository) {
        selectedRepository = $0
      }
      .frame(idealHeight: 200)
    }
  }
}

struct Git_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Git.RootView()
  }
}
