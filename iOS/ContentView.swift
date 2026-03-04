//
//  ContentView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 6/10/22.
//  Updated for 2-tab layout on 1/18/26
//

import SwiftUI

/// Available tools for iOS — matches macOS 2-tab layout
enum iOSTool: String, CaseIterable, Identifiable {
  case repositories = "Repositories"
  case activity = "Activity"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .repositories: "tray.full.fill"
    case .activity: "bolt.fill"
    }
  }
}

/// Entry point for iOS — 2-tab layout matching macOS
struct ContentView: View {
  @State private var selectedTool: iOSTool = .repositories

  var body: some View {
    TabView(selection: $selectedTool) {
      Tab(iOSTool.repositories.rawValue, systemImage: iOSTool.repositories.icon, value: .repositories) {
        iOSRepositoriesView()
      }

      Tab(iOSTool.activity.rawValue, systemImage: iOSTool.activity.icon, value: .activity) {
        iOSActivityView()
      }
    }
  }
}

// MARK: - iOS Repositories View

/// Repositories tab for iOS. Shows GitHub repos with remote-first scope.
struct iOSRepositoriesView: View {
  var body: some View {
    Repositories_RootView(initialScope: .remote)
  }
}

// MARK: - iOS Activity View

/// Activity tab for iOS. Shows swarm membership and worker status.
struct iOSActivityView: View {
  @State private var firebaseService = FirebaseService.shared

  var body: some View {
    NavigationStack {
      Group {
        if !firebaseService.isSignedIn {
          SwarmAuthView()
        } else {
          List {
            // Swarm section
            if !firebaseService.memberSwarms.isEmpty {
              Section("Swarm") {
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
            } else {
              ContentUnavailableView {
                Label("No Activity", systemImage: "bolt.slash")
              } description: {
                Text("Agent activity and swarm monitoring will appear here. Start a swarm on your Mac to see connected workers.")
              }
            }
          }
        }
      }
      .navigationTitle("Activity")
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

#Preview {
  ContentView()
}
