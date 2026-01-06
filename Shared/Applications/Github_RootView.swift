//
//  Github_RootView.swift
//  KitchenSync (macOS)
//
//  Created by Cory Loken on 7/14/21.
//

import SwiftUI
import Github
import Combine
import GithubUI

struct Github_RootView: View {
  @ObservedObject public var viewModel = Github.ViewModel()
  
  @State private var organizations = [Github.User]()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var mainSelection = ["A", "B", "C"]
  @State private var selection: String?
  
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List {
        if Github.hasToken && viewModel.me != nil {
          NavigationLink(
            destination: PersonalView(organizations: organizations)
              .environmentObject(viewModel),
            label: {  ProfileNameView(me: viewModel.me!) }
          )
          Section("Organizations") {
            ForEach(organizations) { organization in
              OrganizationRepositoryView(organization: organization)
            }
          }
        } else {
          Button("Login") {
            Task {
              do {
                try await Github.authorize()
                viewModel.me = try await Github.me()
                organizations = try await Github.loadOrganizations()
              } catch {
                print("Login error: \(error)")
              }
            }
          }
        }
        Spacer()
          .onAppear {
            if Github.hasToken {
              Task {
                do {
                  viewModel.me = try await Github.me()
                  organizations = try await Github.loadOrganizations()
                } catch {
                  print("Error loading user data: \(error)")
                  // Token may be invalid, clear it
                  Github.reauthorize()
                }
              }
            }
          }
      }
    } content: {
      Text("Yo 2")
    } detail: {
      ZStack {
        Text("Select an organization")
      }
    }
    .navigationSplitViewStyle(.automatic)
    .environmentObject(viewModel)
    .frame(idealHeight: 400)
    .toolbar {
#if os(macOS)
      ToggleSidebarToolbarItem(placement: .navigation)
      ToolSelectionToolbar()
#endif
      ToolbarItem(placement: .navigation) {
        Menu {
          Button {
            Github.logout()
            viewModel.me = nil
            organizations = []
          } label: {
            Text("Logout")
            Image(systemName: "figure.wave")
          }
        } label: {
          Image(systemName: "gear")
        }
      }
    }
  }
}

struct Github_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Github_RootView()
  }
}
