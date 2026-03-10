//
//  SwarmInvitesView.swift
//  Peel
//
//  Invites list, invite row, share sheet, and QR code view for swarm invitations
//

import CoreImage
import SwiftUI

// MARK: - Invites List View

struct InvitesListView: View {
  let swarmId: String
  private var firebaseService: FirebaseService { .shared }
  @State private var invites: [InviteDetails] = []
  @State private var isLoading = false
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if invites.isEmpty && !isLoading {
        ContentUnavailableView(
          "No Invites",
          systemImage: "envelope",
          description: Text("Create an invite to share with others")
        )
      } else {
        List(invites) { invite in
          InviteRow(invite: invite, onRevoke: { revokeInvite(invite) })
        }
      }
    }
    .onAppear {
      // Start real-time listener
      firebaseService.startInvitesListener(swarmId: swarmId) { updatedInvites in
        invites = updatedInvites
      }
    }
    .onDisappear {
      firebaseService.stopInvitesListener()
    }
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func revokeInvite(_ invite: InviteDetails) {
    Task {
      do {
        try await firebaseService.revokeInvite(swarmId: swarmId, inviteId: invite.id)
        // Listener updates automatically
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

// MARK: - Invite Row

struct InviteRow: View {
  let invite: InviteDetails
  let onRevoke: () -> Void
  @State private var showingRevokeConfirmation = false

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          statusBadge
          Text("Invite")
            .font(.headline)
        }

        HStack(spacing: 12) {
          Label("\(invite.usedCount)/\(invite.maxUses) uses", systemImage: "person.fill")
          Label(invite.expiresAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Text("Created \(invite.createdAt.formatted(date: .abbreviated, time: .omitted))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Spacer()

      if invite.isValid {
        Button(role: .destructive) {
          showingRevokeConfirmation = true
        } label: {
          Label("Revoke", systemImage: "xmark.circle")
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(.vertical, 4)
    .confirmationDialog("Revoke Invite?", isPresented: $showingRevokeConfirmation) {
      Button("Revoke", role: .destructive) { onRevoke() }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("This invite will no longer work for new users.")
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    let (text, color): (String, Color) = {
      if invite.isRevoked { return ("Revoked", .red) }
      if invite.isExpired { return ("Expired", .orange) }
      if invite.isFullyUsed { return ("Used", .secondary) }
      return ("Active", .green)
    }()

    Text(text)
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(Capsule())
  }
}

// MARK: - Invite Share Sheet

struct InviteShareSheet: View {
  let url: URL?
  let expiresAt: Date?
  let maxUses: Int?
  let usedCount: Int?

  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  init(url: URL?, expiresAt: Date? = nil, maxUses: Int? = nil, usedCount: Int? = nil) {
    self.url = url
    self.expiresAt = expiresAt
    self.maxUses = maxUses
    self.usedCount = usedCount
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        // QR Code
        if let url = url {
          QRCodeView(url: url)
            .frame(width: 200, height: 200)
            .padding()
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        } else {
          Image(systemName: "qrcode")
            .font(.system(size: 120))
            .foregroundStyle(.secondary)
        }

        // URL display
        if let url = url {
          Text(url.absoluteString)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }

        // Expiration and usage info
        if expiresAt != nil || maxUses != nil {
          HStack(spacing: 16) {
            if let expires = expiresAt {
              Label {
                Text(expires, style: .relative)
              } icon: {
                Image(systemName: "clock")
              }
              .font(.caption)
              .foregroundStyle(expires < Date() ? .red : .secondary)
            }

            if let max = maxUses {
              Label {
                Text("\(usedCount ?? 0)/\(max) uses")
              } icon: {
                Image(systemName: "person.2")
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }

        // Action buttons
        HStack(spacing: 12) {
          Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url?.absoluteString ?? "", forType: .string)
            #else
            UIPasteboard.general.string = url?.absoluteString
            #endif
            copied = true

            // Reset after 2 seconds
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(2))
              copied = false
            }
          } label: {
            Label(copied ? "Copied!" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(url == nil)

          #if os(macOS)
          if let url = url {
            ShareLink(item: url) {
              Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
          }
          #endif
        }
        .padding(.horizontal)

        // Instructions
        VStack(spacing: 4) {
          Text("Share this link to invite someone to your swarm.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text("They'll join as a pending member until you approve them.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
      }
      .padding()
      .navigationTitle("Invite Link")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .automatic) {
          HelpButton(topic: .swarmInvites)
        }
      }
    }
    .frame(minWidth: 400, minHeight: 480)
  }
}

// MARK: - QR Code View

struct QRCodeView: View {
  let url: URL

  var body: some View {
    if let image = generateQRCode(from: url.absoluteString) {
      #if os(macOS)
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
      #else
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
      #endif
    } else {
      Image(systemName: "qrcode")
        .font(.system(size: 100))
        .foregroundStyle(.secondary)
    }
  }

  #if os(macOS)
  private func generateQRCode(from string: String) -> NSImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else {
      return nil
    }

    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel") // High error correction

    guard let ciImage = filter.outputImage else { return nil }

    // Scale up for crisp rendering
    let scale = 10.0
    let transform = CGAffineTransform(scaleX: scale, y: scale)
    let scaledImage = ciImage.transformed(by: transform)

    let rep = NSCIImageRep(ciImage: scaledImage)
    let nsImage = NSImage(size: rep.size)
    nsImage.addRepresentation(rep)

    return nsImage
  }
  #else
  private func generateQRCode(from string: String) -> UIImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else {
      return nil
    }

    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel") // High error correction

    guard let ciImage = filter.outputImage else { return nil }

    // Scale up for crisp rendering
    let scale = 10.0
    let transform = CGAffineTransform(scaleX: scale, y: scale)
    let scaledImage = ciImage.transformed(by: transform)

    let context = CIContext()
    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
      return nil
    }

    return UIImage(cgImage: cgImage)
  }
  #endif
}
