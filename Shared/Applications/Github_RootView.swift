//
//  Github_RootView.swift
//  KitchenSync (macOS)
//
//  Created by Cory Loken on 7/14/21.
//  Modernized to @Observable on 1/5/26
//  Updated for Keychain storage on 1/6/26
//

import SwiftUI
import Github

struct Github_RootView: View {
  @State public var viewModel = Github.ViewModel()
  
  @State private var organizations = [Github.User]()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var mainSelection = ["A", "B", "C"]
  @State private var selection: String?
  @State private var hasToken = false
  
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List {
        if hasToken && viewModel.me != nil {
          NavigationLink(
            destination: PersonalView(organizations: organizations),
            label: { ProfileNameView(me: viewModel.me!) }
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
                hasToken = await Github.hasToken
              } catch {
                print("Login error: \(error)")
              }
            }
          }
        }
        Spacer()
          .task {
            hasToken = await Github.hasToken
            if hasToken {
              do {
                viewModel.me = try await Github.me()
                organizations = try await Github.loadOrganizations()
              } catch {
                print("Error loading user data: \(error)")
                // Token may be invalid, clear it
                await Github.reauthorize()
                hasToken = false
              }
          }
        }
      }
    } detail: {
      Text("Select an organization or repository")
        .foregroundStyle(.secondary)
    }
    .navigationSplitViewStyle(.automatic)
    .environment(viewModel)
    .frame(idealHeight: 400)
    .toolbar {
#if os(macOS)
      ToggleSidebarToolbarItem(placement: .navigation)
      ToolSelectionToolbar()
#endif
      ToolbarItem(placement: .navigation) {
        Menu {
          Button {
            Task {
              await Github.reauthorize()
              hasToken = false
              viewModel.me = nil
              organizations = []
            }
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
