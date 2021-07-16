//
//  GithubViewModel.swift
//  GithubViewModel
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
extension Github {
  public class GithubViewModel: ObservableObject {
    @Published public var me: Github.User?
  }
  
  public init() {
//    self.me = me
  }
}
