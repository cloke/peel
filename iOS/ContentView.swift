//
//  ContentView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 6/10/22.
//  Updated for TabView navigation on 1/16/26
//

import SwiftUI

/// Available tools for iOS
/// Note: Workspaces and Agents are macOS-only due to terminal/VM requirements
enum iOSTool: String, CaseIterable, Identifiable {
  case repositories = "Repositories"
  case brew = "Brew"
  case agents = "Agents"
  case swarm = "Swarm"
  
  var id: String { rawValue }
  
  var icon: String {
    switch self {
    case .repositories: "tray.full.fill"
    case .brew: "mug.fill"
    case .agents: "cpu.fill"
    case .swarm: "network"
    }
  }
}

/// Entry point for iOS
struct ContentView: View {
  @State private var selectedTool: iOSTool = .repositories
  
  var body: some View {
    TabView(selection: $selectedTool) {
      Tab(iOSTool.repositories.rawValue, systemImage: iOSTool.repositories.icon, value: .repositories) {
        Repositories_RootView(initialScope: .remote)
      }
      
      Tab(iOSTool.brew.rawValue, systemImage: iOSTool.brew.icon, value: .brew) {
        BrewUnavailableView()
      }
      
      Tab(iOSTool.agents.rawValue, systemImage: iOSTool.agents.icon, value: .agents) {
        AgentsUnavailableView()
      }
      
      Tab(iOSTool.swarm.rawValue, systemImage: iOSTool.swarm.icon, value: .swarm) {
        SwarmMonitorView()
      }
    }
  }
}

/// Placeholder for Brew tab on iOS
struct BrewUnavailableView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Homebrew", systemImage: "mug.fill")
      } description: {
        Text("Homebrew package management is only available on macOS.")
      } actions: {
        Text("Open Peel on your Mac to manage packages.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("Homebrew")
    }
  }
}

/// Placeholder for Agents tab on iOS
struct AgentsUnavailableView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Agents", systemImage: "cpu.fill")
      } description: {
        Text("Agent orchestration requires terminal access and is only available on macOS.")
      } actions: {
        Text("Open Peel on your Mac to use AI agents.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("Agents")
    }
  }
}

#Preview {
  ContentView()
}

// MARK: - Swarm Monitor

/// iOS swarm monitoring view – shows membership and connected workers.
@MainActor
struct SwarmMonitorView: View {
  @State private var firebaseService = FirebaseService.shared

  var body: some View {
    NavigationStack {
      Group {
        if !firebaseService.isSignedIn {
          SwarmAuthView()
        } else if firebaseService.memberSwarms.isEmpty {
          ContentUnavailableView {
            Label("No Swarms", systemImage: "network")
          } description: {
            Text("Join or create a swarm on your Mac.")
          }
        } else {
          List {
            Section("My Swarms") {
              ForEach(firebaseService.memberSwarms) { swarm in
                SwarmMembershipRow(swarm: swarm)
              }
            }

            if !firebaseService.swarmWorkers.isEmpty {
              Section("Connected Workers") {
                ForEach(firebaseService.swarmWorkers) { worker in
                  FirestoreWorkerRow(worker: worker)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Swarm")
    }
  }
}

/// Simple row displaying a swarm membership entry.
private struct SwarmMembershipRow: View {
  let swarm: SwarmMembership

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(swarm.swarmName)
          .font(.subheadline)
          .fontWeight(.medium)
        Text(swarm.role.rawValue.capitalized)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Circle()
        .fill(swarm.role == .pending ? Color.orange : Color.green)
        .frame(width: 8, height: 8)
    }
  }
}
