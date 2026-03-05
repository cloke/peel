//
//  SwarmManagementView.swift
//  Peel
//
//  Main view for managing Firestore-coordinated swarms
//

import SwiftUI
import SwiftData

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
  @State private var showLocalOnly = false
  
  var body: some View {
    Group {
      if firebaseService.isSignedIn || showLocalOnly {
        signedInContent
      } else {
        SwarmAuthView(onSkip: { showLocalOnly = true })
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
    .background {
      #if os(macOS)
      Color(nsColor: .windowBackgroundColor)
      #else
      Color(.systemBackground)
      #endif
    }
    .sheet(isPresented: $showingCreateSwarm) {
      createSwarmSheet
    }
    .onAppear {
      if selectedSwarm == nil {
        selectedSwarm = firebaseService.memberSwarms.first
      }
    }
    .onChange(of: firebaseService.lastJoinedSwarmId) { _, swarmId in
      handleLastJoinedSwarmChange(swarmId)
    }
    .onChange(of: firebaseService.memberSwarms) { _, swarms in
      handleMemberSwarmsChange(swarms)
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


#Preview {
  SwarmManagementView()
}
