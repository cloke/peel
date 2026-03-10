//
//  SwarmDetailView.swift
//  Peel
//
//  Detail view for an individual swarm with tabs for members, workers, invites, and activity
//

import SwiftUI

// MARK: - Swarm Detail View

@MainActor
struct SwarmDetailView: View {
  let swarm: SwarmMembership
  private var firebaseService: FirebaseService { .shared }
  @State private var selectedTab = 0
  @State private var showingInviteSheet = false
  @State private var inviteURL: URL?
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var selectedWorkerForMessage: FirestoreWorker?

  var body: some View {
    VStack(spacing: 0) {
      // Awaiting approval banner for pending members (#237)
      if swarm.role == .pending {
        awaitingApprovalBanner
      }

      // Header
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(swarm.swarmName)
            .font(.title2)
            .fontWeight(.semibold)

          HStack(spacing: 8) {
            RoleBadge(role: swarm.role)
            Text("Joined \(swarm.joinedAt.formatted(date: .abbreviated, time: .omitted))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        if swarm.role.canApproveMembers {
          Button {
            createInvite()
          } label: {
            Label("Invite", systemImage: "person.badge.plus")
          }
          .disabled(isLoading)
        }
      }
      .padding()

      Divider()

      // Content for pending members is limited
      if swarm.role == .pending {
        pendingMemberContent
      } else {
        approvedMemberContent
      }
    }
    .sheet(isPresented: $showingInviteSheet) {
      InviteShareSheet(url: inviteURL)
    }
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .task {
      // Start worker listener for this swarm so the Workers tab count is accurate immediately
      firebaseService.startWorkerListener(swarmId: swarm.id)
      firebaseService.startMessageListener(swarmId: swarm.id)
      if swarm.role.canApproveMembers {
        try? await firebaseService.loadPendingMembers(swarmId: swarm.id)
      }
    }
    .onDisappear {
      firebaseService.stopWorkerListener(swarmId: swarm.id)
      firebaseService.stopMessageListener(swarmId: swarm.id)
    }
  }

  // MARK: - Awaiting Approval Banner (#237)

  @ViewBuilder
  private var awaitingApprovalBanner: some View {
    HStack(spacing: 12) {
      Image(systemName: "clock.badge.questionmark")
        .font(.title2)
        .foregroundStyle(.orange)

      VStack(alignment: .leading, spacing: 2) {
        Text("Awaiting Approval")
          .font(.headline)
        Text("A swarm admin will review your membership request.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding()
    .background(.orange.opacity(0.1))
  }

  // MARK: - Pending Member Content (#237)

  @ViewBuilder
  private var pendingMemberContent: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "person.crop.circle.badge.clock")
        .font(.system(size: 64))
        .foregroundStyle(.secondary)

      Text("Your membership is pending")
        .font(.title3)
        .fontWeight(.medium)

      Text("Once an admin approves your request, you'll be able to:\n• View swarm members and workers\n• Submit tasks and chains\n• Access shared RAG indexes")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Approved Member Content

  @ViewBuilder
  private var approvedMemberContent: some View {
    // Tabs
    Picker("View", selection: $selectedTab) {
      Text("Members").tag(0)
      Text("Workers (\(firebaseService.swarmWorkers.count))").tag(3)
      Text("Chat (\(firebaseService.swarmMessages.count))").tag(5)
      if swarm.role.canApproveMembers {
        Text("Pending (\(firebaseService.pendingMembers.count))").tag(1)
      }
      Text("Invites").tag(2)
      Text("Activity (\(firebaseService.activityLog.count))").tag(4)
    }
    .pickerStyle(.segmented)
    .padding()

    // Content
    Group {
      switch selectedTab {
      case 0:
        MembersListView(swarmId: swarm.id, myRole: swarm.role)
      case 1:
        PendingMembersView(swarmId: swarm.id)
      case 2:
        InvitesListView(swarmId: swarm.id)
      case 3:
        WorkersListView(swarmId: swarm.id, myRole: swarm.role)
      case 5:
        SwarmMessagesView(
          swarmId: swarm.id,
          myRole: swarm.role,
          selectedWorker: $selectedWorkerForMessage
        )
      case 4:
        ActivityLogView()
      default:
        EmptyView()
      }
    }
  }

  private func createInvite() {
    isLoading = true
    Task {
      do {
        let invite = try await firebaseService.createInvite(swarmId: swarm.id)
        inviteURL = invite.url
        showingInviteSheet = true
      } catch {
        errorMessage = error.localizedDescription
      }
      isLoading = false
    }
  }
}

// MARK: - Role Badge

struct RoleBadge: View {
  let role: SwarmPermissionRole

  var body: some View {
    Text(role.rawValue.capitalized)
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(backgroundColor)
      .foregroundStyle(foregroundColor)
      .clipShape(Capsule())
  }

  private var backgroundColor: Color {
    switch role {
    case .owner: return .yellow.opacity(0.2)
    case .admin: return .purple.opacity(0.2)
    case .contributor: return .blue.opacity(0.2)
    case .reader: return .gray.opacity(0.2)
    case .pending: return .orange.opacity(0.2)
    }
  }

  private var foregroundColor: Color {
    switch role {
    case .owner: return .yellow
    case .admin: return .purple
    case .contributor: return .blue
    case .reader: return .secondary
    case .pending: return .orange
    }
  }
}
