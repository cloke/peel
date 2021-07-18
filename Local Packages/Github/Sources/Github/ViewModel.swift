//
//  viewModel.swift
//  viewModel
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import Combine

extension Github {
  public class ViewModel: ObservableObject {
    @AppStorage("github-token") var githubTokenPersisted = ""
    
    @Published public var me: Github.User?
    @Published public var token: String = ""
    
    var disposables = Set<AnyCancellable>()
    
    public init() {
      $token
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink {
          self.githubTokenPersisted = $0
        }
        .store(in: &disposables)
    }
    
    /// Checks to see if the current user is contained in the list of reviewers
    public func hasMe(in reviewers: [User]) -> Bool {
      guard let me = me?.login,
            let _ = reviewers.first(where: { $0.login == me })
      else { return false }
      return true
    }
  }
}
