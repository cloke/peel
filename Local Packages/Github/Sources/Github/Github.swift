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
          if hasToken {
            Text(viewModel.me?.name ?? "")
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
          ForEach(organizations) { organization in
            OrganizationRepositoryView(organization: organization)
          }
        }
        Spacer()
      }
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
      .environmentObject(viewModel)
    }
  }
}

