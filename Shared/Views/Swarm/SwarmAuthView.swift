//
//  SwarmAuthView.swift
//  Peel
//
//  Sign in with Apple for Firestore swarm authentication
//

import SwiftUI
import AuthenticationServices

/// View for signing in with Apple to access Firestore swarms
@MainActor
struct SwarmAuthView: View {
  @State private var firebaseService = FirebaseService.shared
  @State private var isSigningIn = false
  @State private var errorMessage: String?

  /// Optional callback invoked when the user taps "Not now".
  var onSkip: (() -> Void)? = nil
  
  var body: some View {
    VStack(spacing: 24) {
      // Header
      VStack(spacing: 8) {
        Image(systemName: "person.3.fill")
          .font(.system(size: 48))
          .foregroundStyle(.tint)
        
        Text("Join the Swarm")
          .font(.title)
          .fontWeight(.semibold)
        
        Text("Sign in to create or join distributed swarms")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.top, 32)
      
      Spacer()
      
      if !firebaseService.isFirebaseAvailable {
        // Firebase credentials not available — sign-in is not possible
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title2)
            .foregroundStyle(.orange)
          Text("Firebase not configured")
            .font(.subheadline)
            .fontWeight(.medium)
          Text("GoogleService-Info.plist is missing or contains placeholder credentials. Sign-in requires a real Firebase configuration.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
      } else {
        // Sign in button
        SignInWithAppleButton(
        onRequest: { request in
          let (appleRequest, _) = FirebaseService.shared.prepareAppleSignIn()
          request.requestedScopes = appleRequest.requestedScopes
          request.nonce = appleRequest.nonce
        },
        onCompletion: { result in
          handleSignInResult(result)
        }
      )
      .signInWithAppleButtonStyle(.black)
      .frame(height: 50)
      .frame(maxWidth: 280)
      .disabled(isSigningIn)
      
      if isSigningIn {
        ProgressView()
          .padding(.top, 8)
      }
      
      if let error = errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
      } // end else (Firebase available)
      
      Spacer()
      
      // Info footer
      VStack(spacing: 4) {
        if let onSkip {
          Button("Not now") {
            onSkip()
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)

          Text("Local LAN swarm works without sign in.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Swarms enable distributed task execution")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("across multiple Peel instances")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.bottom, 32)
    }
    .padding()
    .frame(minWidth: 320, minHeight: 400)
  }
  
  private func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
    isSigningIn = true
    errorMessage = nil
    
    Task {
      do {
        switch result {
        case .success(let authorization):
          try await FirebaseService.shared.completeAppleSignIn(authorization: authorization)
        case .failure(let error):
          throw error
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      isSigningIn = false
    }
  }
}

#Preview {
  SwarmAuthView()
}
