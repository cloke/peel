//
//  viewModel.swift
//  viewModel
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
extension Github {
  public class ViewModel: ObservableObject {
    @Published public var me: Github.User?
    
    public init() {
  
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
