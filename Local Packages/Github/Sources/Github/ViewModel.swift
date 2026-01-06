//
//  viewModel.swift
//  viewModel
//
//  Created by Cory Loken on 7/15/21.
//  Modernized to @Observable on 1/5/26
//

import SwiftUI

extension Github {
  @MainActor
  @Observable
  public class ViewModel {
    @ObservationIgnored
    @AppStorage("github-token") private var githubTokenPersisted = ""
    
    public var me: Github.User?
    public var token: String = "" {
      didSet {
        githubTokenPersisted = token
      }
    }
    
    public init() {
      // Load token from storage on init
      token = githubTokenPersisted
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
