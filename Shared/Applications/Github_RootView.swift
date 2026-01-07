//
//  Github_RootView.swift
//  KitchenSync (macOS)
//
//  Created by Cory Loken on 7/14/21.
//  Modernized to @Observable on 1/5/26
//  Updated for Keychain storage on 1/6/26
//  Fixed force unwrap and error UI on 1/7/26
//

import SwiftUI
import Github

struct Github_RootView: View {
  @State public var viewModel = Github.ViewModel()
  
  @State private var organizations = [Github.User]()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var hasToken = false
  @State private var isLoading = false
  @State private var errorMessage: String?
  
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List {
        if isLoading {
          ProgressView("Loading...")
        } else if hasToken, let me = viewModel.me {
          NavigationLink(
            destination: PersonalView(organizations: organizations),
            label: { ProfileNameView(me: me) }
          )
          Section("Organizations") {
            ForEach(organizations) { organization in
              OrganizationRepositoryView(organization: organization)
            }
          }
        } else {
          Button("Login") {
            Task { await login() }
          }
        }
      }
      .task {
        await loadInitialData()
      }
    } detail: {
      Text("Select an organization or repository")
        .foregroundStyle(.secondary)
    }
    .navigationSplitViewStyle(.automatic)
    .environment(viewModel)
    .toolbar {
#if os(macOS)
      ToggleSidebarToolbarItem(placement: .navigation)
      ToolSelectionToolbar()
#endif
      ToolbarItem(placement: .navigation) {
        Menu {
          Button {
            Task { await logout() }
          } label: {
            Text("Logout")
            Image(systemName: "figure.wave")
          }
        } label: {
          Image(systemName: "gear")
        }
      }
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }
  
  private func loadInitialData() async {
    hasToken = await Github.hasToken
    guard hasToken else { return }
    
    isLoading = true
    defer { isLoading = false }
    
    do {
      viewModel.me = try await Github.me()
      organizations = try await Github.loadOrganizations()
    } catch {
      errorMessage = "Failed to load user data: \(error.localizedDescription)"
      await Github.reauthorize()
      hasToken = false
    }
  }
  
  private func login() async {
    isLoading = true
    defer { isLoading = false }
    
    do {
      try await Github.authorize()
      viewModel.me = try await Github.me()
      organizations = try await Github.loadOrganizations()
      hasToken = await Github.hasToken
    } catch {
      errorMessage = "Login failed: \(error.localizedDescription)"
    }
  }
  
  private func logout() async {
    await Github.reauthorize()
    hasToken = false
    viewModel.me = nil
    organizations = []
  }
}

#Preview {
  Github_RootView()
}
