//
//  GithubViewModel.swift
//  GithubViewModel
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
extension Github {
  public class ViewModel: ObservableObject {
    @Published public var me: Github.User?
    
    public init() {
  
    }
  }
}
