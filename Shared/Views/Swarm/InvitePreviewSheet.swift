//
//  InvitePreviewSheet.swift
//  Peel
//
//  Shows invite details before accepting - part of #237 deep link flow.
//

import SwiftUI

/// Sheet showing invite preview before accepting
struct InvitePreviewSheet: View {
  let preview: InvitePreview
  @Bindable var firebaseService: FirebaseService
  @Environment(\.dismiss) private var dismiss
  
  @State private var isAccepting = false
  @State private var errorMessage: String?
  
  var body: some View {
    VStack(spacing: 24) {
      // Header
      VStack(spacing: 8) {
        Image(systemName: "person.3.fill")
          .font(.system(size: 48))
          .foregroundStyle(.blue)
        
        Text("Swarm Invite")
          .font(.title2.weight(.semibold))
      }
      .padding(.top, 8)
      
      // Swarm info card
      VStack(alignment: .leading, spacing: 16) {
        // Swarm name
        HStack {
          Label("Swarm", systemImage: "person.3")
            .foregroundStyle(.secondary)
          Spacer()
          Text(preview.swarmName)
            .fontWeight(.medium)
        }
        
        Divider()
        
        // Inviter
        if let inviter = preview.inviterName {
          HStack {
            Label("Invited by", systemImage: "person")
              .foregroundStyle(.secondary)
            Spacer()
            Text(inviter)
          }
          
          Divider()
        }
        
        // Expiration
        HStack {
          Label("Expires", systemImage: "clock")
            .foregroundStyle(.secondary)
          Spacer()
          Text(preview.expiresAt, format: .relative(presentation: .named))
            .foregroundStyle(preview.expiresAt.timeIntervalSinceNow < 3600 ? .orange : .secondary)
        }
        
        Divider()
        
        // Remaining uses
        HStack {
          Label("Remaining uses", systemImage: "number")
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(preview.remainingUses)")
            .foregroundStyle(preview.remainingUses == 1 ? .orange : .secondary)
        }
      }
      .padding()
      .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
      
      // Already member warning
      if preview.isAlreadyMember {
        Label("You're already a member of this swarm", systemImage: "checkmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.green)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      }
      
      // Error message
      if let error = errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      
      // Info text
      Text("You'll join as a pending member until an admin approves your membership.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      
      Spacer()
      
      // Action buttons
      HStack(spacing: 16) {
        Button("Decline") {
          firebaseService.dismissInvitePreview()
          dismiss()
        }
        .buttonStyle(.bordered)
        .disabled(isAccepting)
        
        Button {
          Task {
            await acceptInvite()
          }
        } label: {
          if isAccepting {
            ProgressView()
              .controlSize(.small)
          } else {
            Text(preview.isAlreadyMember ? "View Swarm" : "Accept Invite")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isAccepting)
      }
    }
    .padding(24)
    .frame(width: 360, height: 480)
  }
  
  private func acceptInvite() async {
    if preview.isAlreadyMember {
      // Just close and navigate
      firebaseService.lastJoinedSwarmId = preview.swarmId
      firebaseService.dismissInvitePreview()
      dismiss()
      return
    }
    
    isAccepting = true
    errorMessage = nil
    
    await firebaseService.acceptPendingInvite()
    
    if let error = firebaseService.lastDeepLinkError {
      errorMessage = error
      isAccepting = false
    } else {
      dismiss()
    }
  }
}

#Preview {
  InvitePreviewSheet(
    preview: InvitePreview(
      url: URL(string: "peel://swarm/join?s=test&i=test&t=test")!,
      swarmId: "test-swarm-id",
      swarmName: "My Team Swarm",
      inviteId: "invite-123",
      inviterName: "John Doe",
      expiresAt: Date().addingTimeInterval(86400 * 3),
      remainingUses: 5,
      isAlreadyMember: false
    ),
    firebaseService: .shared
  )
}
