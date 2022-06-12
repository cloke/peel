//
//  Github.swift
//  Github
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI

public struct Github {
  public struct RootView: View {
    @State private var organizations = [User]()
    @ObservedObject var viewModel = ViewModel()
    
    public init() {}
    
    public var body: some View {
      VStack {
        List {
          if hasToken && viewModel.me != nil {
            NavigationLink(
              destination: PersonalView(organizations: organizations)
                .environmentObject(viewModel),
              label: {  ProfileNameView(me: viewModel.me!) }
            )
            ForEach(organizations) { organization in
              OrganizationRepositoryView(organization: organization)
                .environmentObject(viewModel)
            }
            
          } else {
            Button("Login") {
              Task {
                do {
                  try await Github.authorize()
                  viewModel.me = try await Github.me()
                  organizations = try await Github.loadOrganizations()
                }
              }
            }
          }
        }
        Spacer()
          .onAppear {
            if hasToken {
              Task {
                do {
                  try await Github.authorize()
                  viewModel.me = try await Github.me()
                  organizations = try await Github.loadOrganizations()
                }
              }
            }
          }
      }
      .environmentObject(viewModel)
    }
  }
}


