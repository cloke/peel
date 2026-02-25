//
//  SwarmSidebarView.swift
//  Peel
//
//  Sidebar row and local worker status components for SwarmManagementView
//

import SwiftData
import SwiftUI

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
  @Query private var deviceSettings: [DeviceSettings]
  @Environment(\.modelContext) private var modelContext
  @State private var showingOnboardingAlert = false

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

        // Auto-start toggle (device-level setting)
        if let settings = deviceSettings.first {
          Toggle("Auto-start swarm on launch", isOn: Binding(
            get: { settings.swarmAutoStart },
            set: { newValue in
              settings.swarmAutoStart = newValue
              settings.touch()
              try? modelContext.save()
            }
          ))
          .font(.caption2)
        }
      }
    }
    .padding(.vertical, 4)
    .onAppear {
      // Show onboarding hint once when auto-start is enabled
      if let settings = deviceSettings.first, settings.swarmAutoStart && !settings.swarmOnboardingShown {
        showingOnboardingAlert = true
      }
    }
    .alert("Swarm Auto-start", isPresented: $showingOnboardingAlert) {
      Button("Keep Enabled") {
        if let settings = deviceSettings.first {
          settings.swarmOnboardingShown = true
          try? modelContext.save()
        }
      }
      Button("Turn Off") {
        if let settings = deviceSettings.first {
          settings.swarmAutoStart = false
          settings.swarmOnboardingShown = true
          settings.touch()
          try? modelContext.save()
        }
      }
      Button("Dismiss", role: .cancel) {
        if let settings = deviceSettings.first {
          settings.swarmOnboardingShown = true
          try? modelContext.save()
        }
      }
    } message: {
      Text("Peel can automatically join the local swarm on launch so peer discovery (Bonjour) and background workers start immediately. You can turn this off here if you prefer to start the swarm manually.")
    }
  }

  private func startSwarm() {
    isStartingSwarm = true
    Task {
      do {
        // Start coordinator for local LAN discovery
        try coordinator.start(role: .hybrid, port: 8766)

        // Register with all member swarms via Firestore
        // Resolve WAN address so peers can connect across networks
        let wanAddress = await WANAddressResolver.resolve()
        let capabilities = WorkerCapabilities.current(
          wanAddress: wanAddress,
          wanPort: 8766
        )

        for swarm in firebaseService.memberSwarms where swarm.role.canRegisterWorkers {
          _ = try? await firebaseService.registerWorker(swarmId: swarm.id, capabilities: capabilities)
          // Start listening for workers, tasks, and messages from this swarm
          firebaseService.startWorkerListener(swarmId: swarm.id)
          firebaseService.startMessageListener(swarmId: swarm.id)
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
        // Stop listening for workers and messages in this swarm
        firebaseService.stopWorkerListener(swarmId: swarm.id)
        firebaseService.stopMessageListener(swarmId: swarm.id)
      }
      coordinator.stop()
    }
  }
}
