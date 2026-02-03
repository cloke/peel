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
      Text("Workers (\(firebaseService.swarmWorkers.count))").tag(3)
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

// MARK: - Workers List View

@MainActor
struct WorkersListView: View {
  let swarmId: String
  let myRole: SwarmPermissionRole
  @State private var firebaseService = FirebaseService.shared
  @State private var isLoading = false
  @State private var showingMessageSheet = false
  @State private var selectedWorker: FirestoreWorker?
  @State private var messageText = ""
  @State private var messageSent = false
  
  var body: some View {
    VStack(spacing: 0) {
      // Quick action bar
      HStack {
        Text("\(firebaseService.swarmWorkers.filter { !$0.isStale }.count) online")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Spacer()
        
        if myRole.canSubmitTasks {
          Button {
            selectedWorker = nil
            showingMessageSheet = true
          } label: {
            Label("Broadcast", systemImage: "megaphone")
          }
          .buttonStyle(.bordered)
          .help("Send message to all workers")
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      
      Divider()
      
      if firebaseService.swarmWorkers.isEmpty {
        ContentUnavailableView(
          "No Workers Online",
          systemImage: "desktopcomputer",
          description: Text("Workers register when they start their swarm. Run 'swarm.start' to join.")
        )
      } else {
        List(firebaseService.swarmWorkers, id: \.id) { worker in
          WorkerRow(
            worker: worker,
            canMessage: myRole.canSubmitTasks,
            onMessage: {
              selectedWorker = worker
              showingMessageSheet = true
            }
          )
        }
      }
    }
    .task {
      firebaseService.startWorkerListener(swarmId: swarmId)
    }
    .sheet(isPresented: $showingMessageSheet) {
      SendMessageSheet(
        worker: selectedWorker,
        swarmId: swarmId,
        messageText: $messageText,
        onSend: sendMessage
      )
    }
    .alert("Message Sent", isPresented: $messageSent) {
      Button("OK") { }
    } message: {
      Text("Your message has been queued for delivery.")
    }
  }
  
  private func sendMessage() {
    guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    
    Task {
      // TODO: Implement actual message sending via Firestore
      // For now, use the chains.instruct MCP tool pattern
      // This would be: await firebaseService.sendWorkerMessage(swarmId: swarmId, workerId: selectedWorker?.id, message: messageText)
      print("📨 Sending message to \(selectedWorker?.displayName ?? "all workers"): \(messageText)")
      messageText = ""
      showingMessageSheet = false
      messageSent = true
    }
  }
}

// MARK: - Worker Row

struct WorkerRow: View {
  let worker: FirestoreWorker
  let canMessage: Bool
  let onMessage: () -> Void
  
  var body: some View {
    HStack {
      // Status indicator
      Circle()
        .fill(worker.isStale ? .orange : .green)
        .frame(width: 8, height: 8)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(worker.displayName)
          .fontWeight(.medium)
        
        HStack(spacing: 8) {
          Text(worker.deviceName)
            .font(.caption)
            .foregroundStyle(.secondary)
          
          if let version = worker.version {
            Text("v\(version)")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
        
        Text("Last seen \(worker.lastHeartbeat.formatted(.relative(presentation: .named)))")
          .font(.caption2)
          .foregroundStyle(worker.isStale ? Color.orange : Color.secondary)
      }
      
      Spacer()
      
      // Status badge
      Text(worker.status.rawValue.capitalized)
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(worker.isStale ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
        .foregroundStyle(worker.isStale ? .orange : .green)
        .clipShape(Capsule())
      
      if canMessage {
        Button {
          onMessage()
        } label: {
          Image(systemName: "message")
        }
        .buttonStyle(.borderless)
        .help("Send message to this worker")
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Send Message Sheet

struct SendMessageSheet: View {
  let worker: FirestoreWorker?  // nil = broadcast to all
  let swarmId: String
  @Binding var messageText: String
  let onSend: () -> Void
  @Environment(\.dismiss) private var dismiss
  
  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        // Recipient info
        HStack {
          Image(systemName: worker == nil ? "megaphone.fill" : "person.fill")
            .foregroundStyle(.secondary)
          Text(worker == nil ? "Broadcast to all workers" : "Message to \(worker!.displayName)")
            .font(.headline)
          Spacer()
        }
        .padding(.horizontal)
        
        // Message input
        TextEditor(text: $messageText)
          .font(.body)
          .frame(minHeight: 100)
          .padding(8)
          .background(.quaternary)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .padding(.horizontal)
        
        // Suggestions
        VStack(alignment: .leading, spacing: 8) {
          Text("Quick messages:")
            .font(.caption)
            .foregroundStyle(.secondary)
          
          HStack(spacing: 8) {
            QuickMessageButton(text: "Pause current task", messageText: $messageText)
            QuickMessageButton(text: "Focus on tests", messageText: $messageText)
            QuickMessageButton(text: "Skip code review", messageText: $messageText)
          }
        }
        .padding(.horizontal)
        
        Spacer()
      }
      .padding(.top)
      .navigationTitle(worker == nil ? "Broadcast Message" : "Send Message")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") { onSend() }
            .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .frame(minWidth: 450, minHeight: 300)
  }
}

struct QuickMessageButton: View {
  let text: String
  @Binding var messageText: String
  
  var body: some View {
    Button(text) {
      messageText = text
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }
}

// MARK: - Activity Log View

struct ActivityLogView: View {
  @State private var firebaseService = FirebaseService.shared
  @State private var filterType: SwarmActivityType?
  
  var filteredEvents: [SwarmActivityEvent] {
    if let filter = filterType {
      return firebaseService.activityLog.filter { $0.type == filter }
    }
    return firebaseService.activityLog
  }
  
  var body: some View {
    VStack(spacing: 0) {
      // Filter bar
      HStack {
        Text("\(filteredEvents.count) events")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Spacer()
        
        Picker("Filter", selection: $filterType) {
          Text("All Events").tag(nil as SwarmActivityType?)
          Divider()
          Text("🟢 Workers").tag(SwarmActivityType.workerOnline as SwarmActivityType?)
          Text("📤 Tasks").tag(SwarmActivityType.taskSubmitted as SwarmActivityType?)
          Text("⚠️ Errors").tag(SwarmActivityType.error as SwarmActivityType?)
        }
        .pickerStyle(.menu)
        .frame(width: 140)
        
        Button {
          // Clear log
          firebaseService.clearActivityLog()
        } label: {
          Label("Clear", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(firebaseService.activityLog.isEmpty)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      
      Divider()
      
      if filteredEvents.isEmpty {
        ContentUnavailableView(
          "No Activity",
          systemImage: "chart.line.flattrend.xyaxis",
          description: Text("Swarm events like worker registration, tasks, and messages will appear here.")
        )
      } else {
        List(filteredEvents) { event in
          ActivityEventRow(event: event)
        }
        .listStyle(.plain)
      }
    }
  }
}

// MARK: - Activity Event Row

struct ActivityEventRow: View {
  let event: SwarmActivityEvent
  @State private var showingDetails = false
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        Text(event.type.emoji)
          .font(.title3)
        
        VStack(alignment: .leading, spacing: 2) {
          Text(event.message)
            .fontWeight(.medium)
          
          Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        if event.details != nil {
          Button {
            showingDetails.toggle()
          } label: {
            Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
        }
      }
      
      // Details disclosure
      if showingDetails, let details = event.details {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(details.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
            HStack(alignment: .top) {
              Text(key + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
              
              Text(value)
                .font(.caption)
                .textSelection(.enabled)
            }
          }
        }
        .padding(.leading, 32)
        .padding(.top, 4)
      }
    }
    .padding(.vertical, 4)
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
