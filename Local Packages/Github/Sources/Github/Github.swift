//
//  Github.swift
//  Github
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI

public struct Github {
//  public struct RootView: View {
//    @ObservedObject var viewModel = ViewModel()
//
//    @State private var organizations = [User]()
//    @State private var columnVisibility = NavigationSplitViewVisibility.all
//    @State private var mainSelection = ["A", "B", "C"]
//    @State private var selection: String?
//    
//    public init() {}
//    
//    public var body: some View {
//      NavigationSplitView(columnVisibility: $columnVisibility) {
//        List {
//          if hasToken && viewModel.me != nil {
//            NavigationLink(
//              destination: PersonalView(organizations: organizations)
//                .environmentObject(viewModel),
//              label: {  ProfileNameView(me: viewModel.me!) }
//            )
//            Section("Organizations") {
//              ForEach(organizations) { organization in
//                OrganizationRepositoryView(organization: organization)
//                  .environmentObject(viewModel)
//              }
//            }
//          } else {
//            Button("Login") {
//              Task {
//                do {
//                  try await Github.authorize()
//                  viewModel.me = try await Github.me()
//                  organizations = try await Github.loadOrganizations()
//                }
//              }
//            }
//          }
//          Spacer()
//            .onAppear {
//              if hasToken {
//                Task {
//                  do {
//                    try await Github.authorize()
//                    viewModel.me = try await Github.me()
//                    organizations = try await Github.loadOrganizations()
//                  }
//                }
//              }
//            }
//        }
//      } content: {
//        Text("Yo 2")
//      } detail: {
//        ZStack {
//          Text("Select an organization")
//        }
//      }
//      .navigationSplitViewStyle(.automatic)
//      .environmentObject(viewModel)
//      
//    }
//  }
}


