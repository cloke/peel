//
//  VMIsolationView.swift
//  KitchenSync
//
//  Created on 1/16/26.
//
//  UI for monitoring and managing VM-isolated agent execution.
//

import SwiftUI
import AppKit
import Virtualization
import PeelUI

/// Dashboard view for VM Isolation status and management
private enum VMIsolationSection: String, CaseIterable, Identifiable {
  case overview
  case linux
  case console
  case macos
  case pools

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .linux: "Linux"
    case .console: "Console"
    case .macos: "macOS"
    case .pools: "Pools"
    }
  }
}


struct VMIsolationDashboardView: View {
  @Environment(VMIsolationService.self) private var service
  @State private var errorMessage: String?
  @State private var isDownloading = false
  @State private var missingDependencies: [VMToolDependency] = []
  @State private var showingDependenciesPrompt = false
  @State private var isInstallingDependencies = false
  @AppStorage("vm.isolation.section") private var selectedSectionRawValue = VMIsolationSection.overview.rawValue

  private var selectedSection: VMIsolationSection {
    get { VMIsolationSection(rawValue: selectedSectionRawValue) ?? .overview }
    set { selectedSectionRawValue = newValue.rawValue }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Header
        statusHeader

        sectionPicker

        if service.isVirtualizationAvailable {
          sectionContent
        } else {
          unavailableView
        }
      }
      .padding()
    }
    .navigationTitle("VM Isolation")
    .task {
      await service.initialize()
      let missing = service.missingToolDependencies()
      if !missing.isEmpty {
        missingDependencies = missing
        showingDependenciesPrompt = true
      }
    }
    .errorAlert(message: $errorMessage)
    .alert("Install Dependencies?", isPresented: $showingDependenciesPrompt) {
      Button("Install") {
        Task {
          await installMissingDependencies()
        }
      }
      Button("Not Now", role: .cancel) { }
    } message: {
      Text(dependencyPromptMessage)
    }
  }

  // MARK: - Status Header

  private var statusHeader: some View {
    HStack(spacing: 16) {
      Image(systemName: service.isVirtualizationAvailable ? "checkmark.shield.fill" : "xmark.shield.fill")
        .font(.system(size: 32))
        .foregroundStyle(service.isVirtualizationAvailable ? .green : .red)

      VStack(alignment: .leading, spacing: 4) {
        Text("VM Isolation")
          .font(.title2.bold())
        Text(service.statusMessage)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private var sectionPicker: some View {
    Picker("Section", selection: $selectedSectionRawValue) {
      ForEach(VMIsolationSection.allCases) { section in
        Text(section.title).tag(section.rawValue)
      }
    }
    .pickerStyle(.segmented)
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch selectedSection {
    case .overview:
      environmentTiersSection
      VMIsolationSetupView(missingDependencies: $missingDependencies, errorMessage: $errorMessage)
      activeTasksSection
      historySection
    case .linux:
      if service.isLinuxReady {
        VMIsolationLinuxView(errorMessage: $errorMessage)
      } else {
        VMIsolationSetupView(missingDependencies: $missingDependencies, errorMessage: $errorMessage)
      }
    case .console:
      if service.isLinuxReady {
        VMIsolationConsoleView()
      } else {
        VMIsolationSetupView(missingDependencies: $missingDependencies, errorMessage: $errorMessage)
      }
    case .macos:
      if service.isMacOSReady {
        VMIsolationMacOSView(errorMessage: $errorMessage)
      } else {
        VMIsolationSetupView(missingDependencies: $missingDependencies, errorMessage: $errorMessage)
      }
    case .pools:
      if service.isLinuxReady || service.isMacOSReady {
        poolsSection
      } else {
        VMIsolationSetupView(missingDependencies: $missingDependencies, errorMessage: $errorMessage)
      }
    }
  }

  // MARK: - Environment Tiers

  private var environmentTiersSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Execution Environments")
        .font(.headline)

      Text("Tasks automatically use the lightest environment that meets their needs:")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      LazyVGrid(columns: [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
      ], spacing: 12) {
        ForEach(ExecutionEnvironment.allCases, id: \.self) { env in
          EnvironmentTierCard(environment: env)
        }
      }
    }
  }

  // MARK: - Pools Section

  private var poolsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("VM Pools")
        .font(.headline)

      LazyVGrid(columns: [
        GridItem(.flexible()),
        GridItem(.flexible())
      ], spacing: 12) {
        let sortedPools = service.pools.sorted { $0.key < $1.key }
        ForEach(sortedPools, id: \.key) { _, pool in
          VMPoolCard(pool: pool)
        }
      }
    }
  }

  // MARK: - Active Tasks Section

  private var activeTasksSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Active Tasks")
          .font(.headline)
        Spacer()
        Text("\(service.activeTasks.count)")
          .foregroundStyle(.secondary)
      }

      if service.activeTasks.isEmpty {
        ContentUnavailableView {
          Label("No Active Tasks", systemImage: "cpu")
        } description: {
          Text("Tasks running in isolated environments will appear here")
        }
        .frame(height: 120)
      } else {
        ForEach(Array(service.activeTasks.values), id: \.id) { task in
          VMTaskRow(task: task)
        }
      }
    }
  }

  // MARK: - History Section

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Recent History")
          .font(.headline)
        Spacer()
        Text("\(service.taskHistory.count) tasks")
          .foregroundStyle(.secondary)
      }

      if service.taskHistory.isEmpty {
        Text("No task history yet")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding()
      } else {
        ForEach(service.taskHistory.suffix(5), id: \.taskId) { result in
          VMTaskResultRow(result: result)
        }
      }
    }
  }

  // MARK: - Unavailable View

  private var unavailableView: some View {
    ContentUnavailableView {
      Label("VM Isolation Unavailable", systemImage: "xmark.shield")
    } description: {
      VStack(spacing: 8) {
        Text("Virtualization.framework is not available on this system.")
        Text("Requirements:")
          .fontWeight(.medium)
          .padding(.top, 4)
        Text("• macOS 11.0 or later")
        Text("• Apple Silicon or Intel with VT-x")
        Text("• com.apple.security.virtualization entitlement")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  private var dependencyPromptMessage: String {
    let list = missingDependencies.map { "\($0.tool): \($0.purpose)" }.joined(separator: "\n")
    return "Missing tools:\n\(list)\n\nInstall now using Homebrew?"
  }

  private func installMissingDependencies() async {
    isInstallingDependencies = true
    do {
      try await service.installDependencies(missingDependencies)
      missingDependencies = service.missingToolDependencies()
    } catch {
      errorMessage = "Failed to install dependencies: \(error.localizedDescription)"
    }
    isInstallingDependencies = false
  }
}

#Preview {
  NavigationStack {
    VMIsolationDashboardView()
  }
  .frame(width: 700, height: 900)
  .environment(VMIsolationService())
}
