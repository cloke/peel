//
//  GitHubAccountSettingsTab.swift
//  Peel
//
//  Settings tab for managing GitHub account connection.
//

import Github
import PeelUI
import SwiftUI

struct GitHubAccountSettingsTab: View {
  @State private var hasToken = false
  @State private var user: Github.User?
  @State private var isLoading = false
  @State private var isAuthenticating = false
  @State private var errorMessage: String?
  @State private var showSignOutConfirmation = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SectionCard("GitHub Account") {
          if isLoading && user == nil {
            HStack {
              ProgressView()
                .controlSize(.small)
              Text("Loading profile…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          } else if let user {
            signedInSection(user)
          } else {
            signedOutSection
          }

          if let errorMessage {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentMargins(20, for: .scrollContent)
    .task { await loadProfile() }
  }

  // MARK: - Signed In

  private func signedInSection(_ user: Github.User) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        AsyncImage(url: URL(string: user.avatar_url)) { image in
          image
            .resizable()
            .scaledToFill()
            .clipShape(Circle())
        } placeholder: {
          Circle()
            .fill(.quaternary)
            .overlay {
              Image(systemName: "person.fill")
                .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: 2) {
          Text(user.name ?? user.login ?? "GitHub User")
            .font(.headline)
          if let login = user.login {
            Text("@\(login)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        Circle()
          .fill(.green)
          .frame(width: 8, height: 8)
        Text("Connected")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack {
        Button("Refresh") {
          Task { await loadProfile() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer()

        Button("Sign Out", role: .destructive) {
          showSignOutConfirmation = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
    .confirmationDialog("Sign out of GitHub?", isPresented: $showSignOutConfirmation) {
      Button("Sign Out", role: .destructive) {
        Task { await signOut() }
      }
    } message: {
      Text("You'll need to sign in again to access private repositories and pull requests.")
    }
  }

  // MARK: - Signed Out

  private var signedOutSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Circle()
          .fill(.quaternary)
          .overlay {
            Image(systemName: "person.fill")
              .foregroundStyle(.tertiary)
          }
          .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: 2) {
          Text("Not connected")
            .font(.headline)
          Text("Sign in to access private repos and pull requests")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Button {
        Task { await signIn() }
      } label: {
        HStack {
          Image(systemName: "person.badge.key")
          Text(isAuthenticating ? "Signing in…" : "Sign in to GitHub")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .disabled(isAuthenticating)
    }
  }

  // MARK: - Actions

  private func loadProfile() async {
    hasToken = await Github.hasToken
    guard hasToken else {
      user = nil
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      user = try await Github.me()
    } catch {
      user = nil
    }
  }

  private func signIn() async {
    isAuthenticating = true
    errorMessage = nil
    defer { isAuthenticating = false }
    do {
      try await Github.authorize()
      await loadProfile()
    } catch {
      errorMessage = "Login failed: \(error.localizedDescription)"
    }
  }

  private func signOut() async {
    await Github.reauthorize()
    hasToken = false
    user = nil
  }
}
