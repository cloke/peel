//
//  SwarmMembersView.swift
//  Peel
//
//  Members list and pending member approval views for SwarmDetailView
//

import SwiftUI

// MARK: - Members List View

@MainActor
struct MembersListView: View {
  let swarmId: String
  let myRole: SwarmPermissionRole
  var firebaseService = FirebaseService.shared
  @State private var isLoading = false
  @State private var memberToRemove: SwarmMember?

  var body: some View {
    List {
      ForEach(firebaseService.swarmMembers) { member in
        HStack {
          Image(systemName: member.role == .owner ? "crown.fill" : "person.fill")
            .foregroundStyle(member.role == .owner ? .yellow : .secondary)

          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
              Text(member.displayName)
                .fontWeight(.medium)
              if let version = member.codeVersion {
                Text(version.prefix(7))
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .monospaced()
              }
            }
            Text(member.email)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          RoleBadge(role: member.role)

          // Only owner can remove admins/contributors
          if myRole == .owner && member.role != .owner {
            Button(role: .destructive) {
              memberToRemove = member
            } label: {
              Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
          }
        }
        .padding(.vertical, 2)
      }

      if firebaseService.swarmMembers.isEmpty {
        ContentUnavailableView(
          "No Members Yet",
          systemImage: "person.3",
          description: Text("Invite people to join your swarm")
        )
      }
    }
    .confirmationDialog(
      "Remove Member",
      isPresented: .init(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
      titleVisibility: .visible
    ) {
      if let member = memberToRemove {
        Button("Remove \(member.displayName)", role: .destructive) {
          removeMember(member)
        }
        Button("Cancel", role: .cancel) {
          memberToRemove = nil
        }
      }
    } message: {
      if let member = memberToRemove {
        Text("This will remove \(member.displayName) from the swarm. They will need a new invite to rejoin.")
      }
    }
    .onAppear {
      // Start real-time listener
      firebaseService.startMembersListener(swarmId: swarmId)
    }
    .onDisappear {
      // Stop listener when view disappears
      firebaseService.stopMembersListener()
    }
  }

  private func removeMember(_ member: SwarmMember) {
    isLoading = true
    Task {
      try? await firebaseService.revokeMember(swarmId: swarmId, userId: member.id)
      // No need to reload - listener will update automatically
      memberToRemove = nil
      isLoading = false
    }
  }
}

// MARK: - Pending Members View

@MainActor
struct PendingMembersView: View {
  let swarmId: String
  private var firebaseService: FirebaseService { .shared }
  @State private var isLoading = false
  @State private var memberToReject: SwarmMember?

  var body: some View {
    List {
      ForEach(firebaseService.pendingMembers) { member in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(member.displayName)
              .fontWeight(.medium)
            Text(member.email)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Button("Approve") {
            approve(member)
          }
          .buttonStyle(.borderedProminent)
          .disabled(isLoading)

          Button("Reject", role: .destructive) {
            memberToReject = member
          }
          .buttonStyle(.bordered)
          .disabled(isLoading)
        }
        .padding(.vertical, 4)
      }

      if firebaseService.pendingMembers.isEmpty {
        ContentUnavailableView(
          "No Pending Members",
          systemImage: "checkmark.circle",
          description: Text("All membership requests have been processed")
        )
      }
    }
    .confirmationDialog(
      "Reject Member",
      isPresented: .init(get: { memberToReject != nil }, set: { if !$0 { memberToReject = nil } }),
      titleVisibility: .visible
    ) {
      if let member = memberToReject {
        Button("Reject \(member.displayName)", role: .destructive) {
          reject(member)
        }
        Button("Cancel", role: .cancel) {
          memberToReject = nil
        }
      }
    } message: {
      if let member = memberToReject {
        Text("This will deny \(member.displayName)'s request to join. They will need a new invite.")
      }
    }
    // Note: Members listener in MembersListView also updates pendingMembers
  }

  private func approve(_ member: SwarmMember) {
    isLoading = true
    Task {
      try? await firebaseService.approveMember(
        swarmId: swarmId,
        userId: member.id,
        role: .contributor
      )
      // Listener updates automatically
      isLoading = false
    }
  }

  private func reject(_ member: SwarmMember) {
    isLoading = true
    Task {
      try? await firebaseService.revokeMember(swarmId: swarmId, userId: member.id)
      // Listener updates automatically
      memberToReject = nil
      isLoading = false
    }
  }
}
