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
              Github.authorize(success:  {
                Github.me {
                  viewModel.me = $0
                }
                Github.loadOrganizations() {
                  organizations = $0
                }
              })
            }
          }
        }
        Spacer()
          .onAppear {
            if hasToken {
              Github.authorize(success:  {
                Github.me {
                  viewModel.me = $0
                }
                Github.loadOrganizations() {
                  organizations = $0
                }
              })
            }
          }
      }
      .environmentObject(viewModel)
    }
  }
}


