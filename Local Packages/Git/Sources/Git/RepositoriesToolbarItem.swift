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
  
  public init(repositories: [Model.Repository], selectedRepository: Binding<Model.Repository>) {
    self.repositories = repositories
    self._selectedRepository = selectedRepository
  }
  
  public var body: some ToolbarContent {
    ToolbarItem(placement: ToolbarItemPlacement.primaryAction) {
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
