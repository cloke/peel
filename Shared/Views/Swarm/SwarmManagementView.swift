//
//  SwarmManagementView.swift
//  Peel
//
//  Main view for managing Firestore-coordinated swarms
//

import SwiftUI

/// Main swarm management view - shows swarms, members, invites
@MainActor
struct SwarmManagementView: View {
  @State private var firebaseService = FirebaseService.shared
  @State private var selectedSwarm: SwarmMembership?
  @State private var showingCreateSwarm = false
  @State private var showingCreateInvite = false
  @State private var newSwarmName = ""
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var showingDeepLinkAlert = false
  @State private var showingInvitePreview = false
  
  var body: some View {
    Group {
      if firebaseService.isSignedIn {
        signedInContent
      } else {
        SwarmAuthView()
      }
    }
    .onChange(of: firebaseService.deepLinkReceived) { _, received in
      if received {
        firebaseService.deepLinkReceived = false
        // Show preview sheet if we have one, otherwise show error alert
        if firebaseService.pendingInvitePreview != nil {
          showingInvitePreview = true
        } else if firebaseService.lastDeepLinkError != nil || firebaseService.pendingInviteURL != nil {
          showingDeepLinkAlert = true
        }
      }
    }
    .sheet(isPresented: $showingInvitePreview) {
      if let preview = firebaseService.pendingInvitePreview {
        InvitePreviewSheet(preview: preview, firebaseService: firebaseService)
      }
    }
    .alert("Swarm Invite", isPresented: $showingDeepLinkAlert) {
      Button("OK") { }
    } message: {
      if let error = firebaseService.lastDeepLinkError {
        Text(error)
      } else if firebaseService.pendingInviteURL != nil {
        Text("Sign in to accept this invite")
      } else {
        Text("Invite processed")
      }
    }
  }
  
  @ViewBuilder
  private var signedInContent: some View {
    HSplitView {
      // Sidebar
      VStack(spacing: 0) {
        sidebarContent
      }
      .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
      
      // Detail
      if let swarm = selectedSwarm {
        SwarmDetailView(swarm: swarm)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "Select a Swarm",
          systemImage: "person.3",
          description: Text("Choose a swarm from the sidebar or create a new one")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheet(isPresented: $showingCreateSwarm) {
      createSwarmSheet
    }
    .onChange(of: firebaseService.lastJoinedSwarmId) { _, swarmId in
      handleLastJoinedSwarmChange(swarmId)
    }
    .onChange(of: firebaseService.memberSwarms) { _, swarms in
      handleMemberSwarmsChange(swarms)
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      if let error = errorMessage {
        Text(error)
      }
    }
  }
  
  // MARK: - Handlers (#236)
  
  /// Auto-select newly joined swarm after accepting invite
  private func handleLastJoinedSwarmChange(_ swarmId: String?) {
    guard let swarmId = swarmId,
          let swarm = firebaseService.memberSwarms.first(where: { $0.id == swarmId }) else {
      return
    }
    selectedSwarm = swarm
    FirebaseService.shared.lastJoinedSwarmId = nil
  }
  
  /// Auto-select newly joined swarm after swarms reload
  private func handleMemberSwarmsChange(_ swarms: [SwarmMembership]) {
    guard let swarmId = firebaseService.lastJoinedSwarmId,
          let swarm = swarms.first(where: { $0.id == swarmId }) else {
      return
    }
    selectedSwarm = swarm
    FirebaseService.shared.lastJoinedSwarmId = nil
  }
  
  @ViewBuilder
  private var sidebarContent: some View {
    VStack(spacing: 0) {
      // Toolbar header
      HStack {
        Text("Swarms")
          .font(.headline)
        Spacer()
        Button {
          showingCreateSwarm = true
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Create new swarm")
        
        Menu {
          Button("Sign Out", role: .destructive) {
            try? firebaseService.signOut()
          }
        } label: {
          Image(systemName: "person.circle")
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      
      Divider()
      
      // Swarm list
      List(selection: $selectedSwarm) {
        Section {
          ForEach(firebaseService.memberSwarms) { swarm in
            SwarmRowView(swarm: swarm)
              .tag(swarm)
          }
          
          if firebaseService.memberSwarms.isEmpty {
            Text("No swarms yet")
              .foregroundStyle(.secondary)
              .italic()
          }
        } header: {
          HStack(spacing: 4) {
            Text("My Swarms")
            HelpButton(topic: .swarmSetup)
          }
        }
      }
      .listStyle(.sidebar)
    }
  }
  
  @ViewBuilder
  private var createSwarmSheet: some View {
    NavigationStack {
      Form {
        Section("Swarm Details") {
          TextField("Swarm Name", text: $newSwarmName)
            .textFieldStyle(.roundedBorder)
        }
        
        Section {
          Text("You'll be the owner of this swarm and can invite others to join.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Create Swarm")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            showingCreateSwarm = false
            newSwarmName = ""
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            createSwarm()
          }
          .disabled(newSwarmName.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        }
      }
    }
    .frame(minWidth: 400, minHeight: 200)
  }
  
  private func createSwarm() {
    isLoading = true
    Task {
      do {
        _ = try await firebaseService.createSwarm(name: newSwarmName)
        showingCreateSwarm = false
        newSwarmName = ""
      } catch {
        errorMessage = error.localizedDescription
      }
      isLoading = false
    }
  }
}

// MARK: - Swarm Row

struct SwarmRowView: View {
  let swarm: SwarmMembership
  
  var body: some View {
    HStack {
      Image(systemName: swarm.role == .owner ? "crown.fill" : "person.3.fill")
        .foregroundStyle(swarm.role == .owner ? .yellow : .secondary)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(swarm.swarmName)
          .fontWeight(.medium)
        
        Text(swarm.role.rawValue.capitalized)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Swarm Detail View

@MainActor
struct SwarmDetailView: View {
  let swarm: SwarmMembership
  @State private var firebaseService = FirebaseService.shared
  @State private var selectedTab = 0
  @State private var showingInviteSheet = false
  @State private var inviteURL: URL?
  @State private var isLoading = false
  @State private var errorMessage: String?
  
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
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      if let error = errorMessage {
        Text(error)
      }
    }
    .task {
      if swarm.role.canApproveMembers {
        try? await firebaseService.loadPendingMembers(swarmId: swarm.id)
      }
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
      if swarm.role.canApproveMembers {
        Text("Pending (\(firebaseService.pendingMembers.count))").tag(1)
      }
      Text("Invites").tag(2)
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

// MARK: - Placeholder Views

// MARK: - Members List View

@MainActor
struct MembersListView: View {
  let swarmId: String
  let myRole: SwarmPermissionRole
  @State private var firebaseService = FirebaseService.shared
  @State private var isLoading = false
  @State private var memberToRemove: SwarmMember?
  
  var body: some View {
    List {
      ForEach(firebaseService.swarmMembers) { member in
        HStack {
          Image(systemName: member.role == .owner ? "crown.fill" : "person.fill")
            .foregroundStyle(member.role == .owner ? .yellow : .secondary)
          
          VStack(alignment: .leading, spacing: 2) {
            Text(member.displayName)
              .fontWeight(.medium)
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
    .task {
      await loadMembers()
    }
  }
  
  private func loadMembers() async {
    isLoading = true
    try? await firebaseService.loadSwarmMembers(swarmId: swarmId)
    isLoading = false
  }
  
  private func removeMember(_ member: SwarmMember) {
    isLoading = true
    Task {
      try? await firebaseService.revokeMember(swarmId: swarmId, userId: member.id)
      await loadMembers()
      memberToRemove = nil
      isLoading = false
    }
  }
}

@MainActor
struct PendingMembersView: View {
  let swarmId: String
  @State private var firebaseService = FirebaseService.shared
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
  }
  
  private func approve(_ member: SwarmMember) {
    isLoading = true
    Task {
      try? await firebaseService.approveMember(
        swarmId: swarmId,
        userId: member.id,
        role: .contributor
      )
      try? await firebaseService.loadPendingMembers(swarmId: swarmId)
      isLoading = false
    }
  }
  
  private func reject(_ member: SwarmMember) {
    isLoading = true
    Task {
      try? await firebaseService.revokeMember(swarmId: swarmId, userId: member.id)
      try? await firebaseService.loadPendingMembers(swarmId: swarmId)
      memberToReject = nil
      isLoading = false
    }
  }
}

struct InvitesListView: View {
  let swarmId: String
  @State private var firebaseService = FirebaseService.shared
  @State private var invites: [InviteDetails] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  
  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading invites...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if invites.isEmpty {
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
    .task {
      await loadInvites()
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      if let error = errorMessage {
        Text(error)
      }
    }
  }
  
  private func loadInvites() async {
    isLoading = true
    do {
      invites = try await firebaseService.loadInvites(swarmId: swarmId)
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }
  
  private func revokeInvite(_ invite: InviteDetails) {
    Task {
      do {
        try await firebaseService.revokeInvite(swarmId: swarmId, inviteId: invite.id)
        await loadInvites()
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
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false
  
  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "qrcode")
          .font(.system(size: 120))
          .foregroundStyle(.secondary)
        
        if let url = url {
          Text(url.absoluteString)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding()
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
          
          Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            #endif
            copied = true
          } label: {
            Label(copied ? "Copied!" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .buttonStyle(.borderedProminent)
        }
        
        Text("Share this link with someone to invite them to your swarm.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        
        Text("They'll join as a pending member until you approve them.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
    .frame(minWidth: 400, minHeight: 400)
  }
}

#Preview {
  SwarmManagementView()
}
