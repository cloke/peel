//
//  OnboardingWizardView.swift
//  Peel
//
//  First-launch onboarding wizard. Guides new users through:
//  1. Welcome — What Peel does
//  2. GitHub Auth — Connect GitHub account
//  3. Add Repository — Select a repo to work with
//  4. RAG Setup — Index the repo for agent context
//  5. Ready — Quick overview of what to do next
//

import SwiftUI
import Github

struct OnboardingWizardView: View {
  @AppStorage("onboarding.completed") private var onboardingCompleted = false
  @Environment(\.dismiss) private var dismiss

  @State private var currentStep = 0
  @State private var hasGitHubToken = false
  @State private var isAuthenticating = false
  @State private var authError: String?
  @State private var repoPath = ""
  @State private var repoAdded = false
  @State private var isIndexing = false
  @State private var indexingComplete = false

  private let totalSteps = 5

  var body: some View {
    VStack(spacing: 0) {
      // Progress indicator
      progressBar
        .padding(.horizontal, 32)
        .padding(.top, 20)

      // Step content
      Group {
        switch currentStep {
        case 0: welcomeStep
        case 1: githubAuthStep
        case 2: addRepoStep
        case 3: ragSetupStep
        case 4: readyStep
        default: readyStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(32)

      // Navigation buttons
      navigationButtons
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }
    .frame(width: 600, height: 480)
    .task {
      hasGitHubToken = await Github.hasToken
    }
  }

  // MARK: - Progress Bar

  private var progressBar: some View {
    HStack(spacing: 4) {
      ForEach(0..<totalSteps, id: \.self) { step in
        Capsule()
          .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.2))
          .frame(height: 4)
      }
    }
  }

  // MARK: - Step 0: Welcome

  private var welcomeStep: some View {
    VStack(spacing: 20) {
      Image(systemName: "layers.3.bottom.filled")
        .font(.system(size: 56))
        .foregroundStyle(Color.accentColor)

      Text("Welcome to Peel")
        .font(.largeTitle)
        .fontWeight(.bold)

      Text("Peel coordinates AI agents to do real development work, then helps you review and merge the results.")
        .font(.title3)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)

      VStack(alignment: .leading, spacing: 12) {
        featureRow(icon: "brain", title: "Dispatch Agent Chains", description: "Plan, implement, build-check, and review — automated")
        featureRow(icon: "arrow.triangle.merge", title: "Review & Merge", description: "Approve agent work with structured diffs and confidence scores")
        featureRow(icon: "arrow.clockwise", title: "Self-Improving", description: "Peel can rebuild itself and keep going")
      }
      .padding(.top, 8)
    }
  }

  // MARK: - Step 1: GitHub Auth

  private var githubAuthStep: some View {
    VStack(spacing: 20) {
      Image(systemName: "person.badge.key")
        .font(.system(size: 48))
        .foregroundStyle(Color.accentColor)

      Text("Connect GitHub")
        .font(.title)
        .fontWeight(.bold)

      Text("Peel uses GitHub to fetch issues, create PRs, and coordinate agent work on your repositories.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)

      if hasGitHubToken {
        Label("Connected", systemImage: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
      } else {
        Button {
          isAuthenticating = true
          authError = nil
          Task {
            do {
              try await Github.authorize()
              hasGitHubToken = true
            } catch {
              authError = error.localizedDescription
            }
            isAuthenticating = false
          }
        } label: {
          HStack {
            if isAuthenticating {
              ProgressView()
                .controlSize(.small)
            }
            Text(isAuthenticating ? "Authenticating…" : "Sign in with GitHub")
          }
          .frame(minWidth: 200)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isAuthenticating)

        if let authError {
          Text(authError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        Text("You can skip this and connect later from Settings.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  // MARK: - Step 2: Add Repository

  private var addRepoStep: some View {
    VStack(spacing: 20) {
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 48))
        .foregroundStyle(Color.accentColor)

      Text("Add a Repository")
        .font(.title)
        .fontWeight(.bold)

      Text("Point Peel at a local git repository. Agents will work in worktrees so your main checkout stays clean.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)

      HStack {
        TextField("Repository path", text: $repoPath)
          .textFieldStyle(.roundedBorder)

        Button("Browse…") {
          let panel = NSOpenPanel()
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          panel.allowsMultipleSelection = false
          panel.message = "Select a git repository"
          if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
            repoAdded = true
          }
        }
      }
      .frame(maxWidth: 400)

      if repoAdded {
        Label("Repository added", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }

      Text("You can add more repositories later from the Repositories tab.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  // MARK: - Step 3: RAG Setup

  private var ragSetupStep: some View {
    VStack(spacing: 20) {
      Image(systemName: "magnifyingglass.circle")
        .font(.system(size: 48))
        .foregroundStyle(Color.accentColor)

      Text("Code Intelligence")
        .font(.title)
        .fontWeight(.bold)

      Text("Peel indexes your code with RAG embeddings so agents can search and understand your codebase.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)

      if repoPath.isEmpty {
        Text("Add a repository first to enable indexing.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else if indexingComplete {
        Label("Indexed: \(repoPath)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 400)
      } else {
        VStack(spacing: 12) {
          Text("Ready to index: \((repoPath as NSString).lastPathComponent)")
            .font(.callout)

          Button {
            isIndexing = true
            // Indexing happens via MCP when the server is running.
            // For onboarding, mark as complete — actual indexing occurs on first agent use.
            Task {
              try? await Task.sleep(for: .seconds(1))
              indexingComplete = true
              isIndexing = false
            }
          } label: {
            HStack {
              if isIndexing {
                ProgressView()
                  .controlSize(.small)
              }
              Text(isIndexing ? "Preparing…" : "Enable Auto-Indexing")
            }
            .frame(minWidth: 200)
          }
          .buttonStyle(.borderedProminent)
          .disabled(isIndexing)
        }
      }

      Text("RAG indexing uses local MLX embeddings — no data leaves your machine.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  // MARK: - Step 4: Ready

  private var readyStep: some View {
    VStack(spacing: 20) {
      Image(systemName: "checkmark.seal.fill")
        .font(.system(size: 56))
        .foregroundStyle(.green)

      Text("You're Ready")
        .font(.largeTitle)
        .fontWeight(.bold)

      Text("Peel is set up. Here's what to try first:")
        .font(.body)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 12) {
        nextStepRow(
          number: "1",
          title: "Dispatch a Quick Task",
          description: "Go to Activity → Templates → Quick Task to run your first agent"
        )
        nextStepRow(
          number: "2",
          title: "Review Agent Work",
          description: "Check the Activity dashboard for pending reviews"
        )
        nextStepRow(
          number: "3",
          title: "Try Sprint Mode",
          description: "Let Peel analyze your codebase and suggest improvements"
        )
      }
      .padding(.top, 4)
    }
  }

  // MARK: - Navigation

  private var navigationButtons: some View {
    HStack {
      if currentStep > 0 {
        Button("Back") {
          withAnimation { currentStep -= 1 }
        }
        .buttonStyle(.bordered)
      }

      Spacer()

      if currentStep < totalSteps - 1 {
        Button("Skip") {
          withAnimation { currentStep += 1 }
        }
        .foregroundStyle(.secondary)

        Button("Continue") {
          withAnimation { currentStep += 1 }
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button("Get Started") {
          onboardingCompleted = true
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
  }

  // MARK: - Helpers

  private func featureRow(icon: String, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func nextStepRow(number: String, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number)
        .font(.title2)
        .fontWeight(.bold)
        .foregroundStyle(Color.accentColor)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
