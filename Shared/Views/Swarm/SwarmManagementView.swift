//
//  SwarmManagementView.swift
//  Peel
//
//  Main view for managing Firestore-coordinated swarms
//

import CoreImage
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
        
        // Local Worker Section
        Section {
          LocalWorkerStatusView()
        } header: {
          HStack(spacing: 4) {
            Text("This Device")
            HelpButton(topic: .swarmWorkers)
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

// MARK: - Local Worker Status View

@MainActor
struct LocalWorkerStatusView: View {
  @State private var coordinator = SwarmCoordinator.shared
  @State private var firebaseService = FirebaseService.shared
  @State private var isStartingSwarm = false
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Worker Status
      HStack {
        Circle()
          .fill(coordinator.isActive ? .green : .gray)
          .frame(width: 8, height: 8)
        
        Text(coordinator.isActive ? coordinator.role.rawValue.capitalized : "Offline")
          .font(.caption)
          .fontWeight(.medium)
      }
      
      if coordinator.isActive {
        // Show stats
        VStack(alignment: .leading, spacing: 4) {
          Text("\(coordinator.tasksCompleted) tasks completed")
            .font(.caption2)
            .foregroundStyle(.secondary)
          
          if coordinator.currentTask != nil {
            HStack(spacing: 4) {
              ProgressView()
                .scaleEffect(0.5)
              Text("Working...")
                .font(.caption2)
                .foregroundStyle(.blue)
            }
          }
        }
        
        // Stop button
        Button {
          stopSwarm()
        } label: {
          HStack {
            Image(systemName: "stop.fill")
            Text("Stop")
          }
          .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(.red)
      } else {
        // Start button
        Button {
          startSwarm()
        } label: {
          HStack {
            if isStartingSwarm {
              ProgressView()
                .scaleEffect(0.7)
            } else {
              Image(systemName: "play.fill")
            }
            Text("Join Swarm")
          }
          .font(.caption)
        }
        .buttonStyle(.bordered)
        .disabled(isStartingSwarm || firebaseService.memberSwarms.isEmpty)
        
        if firebaseService.memberSwarms.isEmpty {
          Text("Join a swarm first")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }
  
  private func startSwarm() {
    isStartingSwarm = true
    Task {
      do {
        // Start coordinator for local LAN discovery
        try coordinator.start(role: .hybrid, port: 8766)
        
        // Register with all member swarms via Firestore (no direct connections needed!)
        let capabilities = WorkerCapabilities.current()
        
        for swarm in firebaseService.memberSwarms where swarm.role.canRegisterWorkers {
          _ = try? await firebaseService.registerWorker(swarmId: swarm.id, capabilities: capabilities)
          // Start listening for tasks from this swarm
          firebaseService.startWorkerListener(swarmId: swarm.id)
        }
      } catch {
        print("Failed to start swarm: \(error)")
      }
      isStartingSwarm = false
    }
  }
  
  private func stopSwarm() {
    Task {
      // Unregister from all swarms
      for swarm in firebaseService.memberSwarms {
        try? await firebaseService.unregisterWorker(swarmId: swarm.id)
      }
      coordinator.stop()
    }
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
  @State private var showingMessageSheet = false
  @State private var selectedWorker: FirestoreWorker?
  @State private var messageText = ""
  @State private var messageSent = false
  
  var body: some View {
    VStack(spacing: 0) {
      // Info banner explaining how Firestore swarm works
      if !firebaseService.swarmWorkers.isEmpty {
        firestoreInfoBanner
      }
      
      // Quick action bar
      HStack {
        Text("\(firebaseService.swarmWorkers.filter { !$0.isStale }.count) workers online")
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
          description: Text("Workers automatically connect when they join this swarm. Click 'Join Swarm' in the sidebar to participate.")
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
  
  // MARK: - Firestore Info Banner
  
  @ViewBuilder
  private var firestoreInfoBanner: some View {
    HStack(spacing: 12) {
      Image(systemName: "cloud.fill")
        .font(.title3)
        .foregroundStyle(.blue)
      
      VStack(alignment: .leading, spacing: 2) {
        Text("Cloud Coordinated")
          .font(.caption)
          .fontWeight(.medium)
        
        Text("Workers communicate via Firestore - no network config needed")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.blue.opacity(0.05))
  }
  
  private func sendMessage() {
    guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    
    Task {
      // TODO: Implement actual message sending via Firestore
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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

#Preview {
  SwarmManagementView()
}
