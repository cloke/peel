//
//  GitHubAccountView.swift
//  Peel
//
//  GitHub account indicator for the sidebar.
//  Shows sign-in button when unauthenticated, profile when signed in.
//

import Github
import SwiftUI

/// Compact GitHub account indicator for the sidebar bottom.
struct GitHubAccountView: View {
  @State private var hasToken = false
  @State private var user: Github.User?
  @State private var isLoading = false
  @State private var isAuthenticating = false
  @State private var errorMessage: String?
  @State private var showSignOutConfirmation = false

  var body: some View {
    Group {
      if isLoading && user == nil {
        loadingView
      } else if let user {
        signedInView(user)
      } else {
        signInView
      }
    }
    .task { await loadProfile() }
  }

  // MARK: - Signed In

  private func signedInView(_ user: Github.User) -> some View {
    HStack(spacing: 8) {
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
              .font(.caption2)
          }
      }
      .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 0) {
        Text(user.name ?? user.login ?? "GitHub")
          .font(.caption)
          .fontWeight(.medium)
          .lineLimit(1)
        if let login = user.login, login != user.name {
          Text("@\(login)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button("Sign Out of GitHub", role: .destructive) {
        showSignOutConfirmation = true
      }
      Button("Refresh Profile") {
        Task { await loadProfile() }
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

  // MARK: - Sign In

  private var signInView: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        Task { await signIn() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "person.badge.key")
            .font(.caption)
          Text(isAuthenticating ? "Signing in…" : "Sign in to GitHub")
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.blue)
      .disabled(isAuthenticating)

      if let errorMessage {
        Text(errorMessage)
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
  }

  // MARK: - Loading

  private var loadingView: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.mini)
      Text("Loading profile…")
        .font(.caption)
        .foregroundStyle(.secondary)
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
      // Token may be expired — don't clear it, just show signed-in state without name
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
