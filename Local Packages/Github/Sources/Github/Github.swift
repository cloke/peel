//
//  Github.swift
//  Github
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI

public struct Github {
  public struct RootView: View {
    @State private var organizations = [Organization]()
    @ObservedObject var githubViewModel = ViewModel()
    
    public init() {}
    
    public var body: some View {
      VStack {
        List {
          Text(githubViewModel.me?.name ?? "")
          Button("Login") {
            Github.authorize(success:  {
              Github.me {
                githubViewModel.me = $0
              }
              Github.loadOrganizations() {
                organizations = $0
              }
            })
          }
          
          ForEach(organizations) { organization in
            OrganizationRepositoryView(organization: organization)
          }
        }
        Spacer()
      }
      .environmentObject(githubViewModel)
    }
  }
}

