//
//  File.swift
//  
//
//  Created by Cory Loken on 1/30/21.
//

import SwiftUI

/// The container application will use this to inject custom controls into the window UI.
public struct RepositoriesMenuToolbarItem: ToolbarContent {
  @Binding private var selectedRepository: Model.Repository
  private let repositories: [Model.Repository]
  private let onAddRepository: (() -> Void)?
  private let onCloneRepository: (() -> Void)?
  
  public init(
    repositories: [Model.Repository],
    selectedRepository: Binding<Model.Repository>,
    onAddRepository: (() -> Void)? = nil,
    onCloneRepository: (() -> Void)? = nil
  ) {
    self.repositories = repositories
    self._selectedRepository = selectedRepository
    self.onAddRepository = onAddRepository
    self.onCloneRepository = onCloneRepository
  }
  
  public var body: some ToolbarContent {
    ToolbarItem(placement: ToolbarItemPlacement.primaryAction) {
      Menu {
        if let onAddRepository {
          Button("Open Repository…", action: onAddRepository)
        }
        if let onCloneRepository {
          Button("Clone Repository…", action: onCloneRepository)
        }
        if onAddRepository != nil || onCloneRepository != nil {
          Divider()
        }
        ForEach(repositories) { repository in
          Button(repository.name) {
            selectedRepository = repository
          }
        }
      } label: {
        Label(selectedRepository.name, systemImage: "folder")
      }
    }
  }
}
