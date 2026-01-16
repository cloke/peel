//
//  VMIsolationView.swift
//  KitchenSync
//
//  Created on 1/16/26.
//
//  UI for monitoring and managing VM-isolated agent execution.
//

#if os(macOS)

import SwiftUI

/// Dashboard view for VM Isolation status and management
struct VMIsolationDashboardView: View {
  @State private var service = VMIsolationService()
  @State private var errorMessage: String?
  @State private var showingError = false
  @State private var isDownloading = false
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Header
        statusHeader
        
        if service.isVirtualizationAvailable {
          // Environment tiers explanation
          environmentTiersSection
          
          // Setup status
          setupStatusSection
          
          // Test VM section (when Linux is ready)
          if service.isLinuxReady {
            testVMSection
          }
          
          // VM Pools
          if service.isLinuxReady || service.isMacOSReady {
            poolsSection
          }
          
          // Active Tasks
          activeTasksSection
          
          // Recent History
          historySection
        } else {
          unavailableView
        }
      }
      .padding()
    }
    .navigationTitle("VM Isolation")
    .task {
      await service.initialize()
    }
    .alert("Error", isPresented: $showingError) {
      Button("OK") { }
    } message: {
      Text(errorMessage ?? "Unknown error")
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
  
  // MARK: - Setup Status
  
  private var setupStatusSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Setup Status")
        .font(.headline)
      
      HStack(spacing: 20) {
        // Linux VM status
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Image(systemName: service.isLinuxReady ? "checkmark.circle.fill" : "circle.dashed")
              .foregroundStyle(service.isLinuxReady ? .green : .secondary)
            Text("Linux VMs")
              .fontWeight(.medium)
            
            Text("Recommended")
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.green.opacity(0.2), in: Capsule())
              .foregroundStyle(.green)
          }
          
          if service.isLinuxReady {
            Text("Alpine Linux ready (~50MB)")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Fast boot (~3s), minimal footprint")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            Button {
              Task {
                isDownloading = true
                do {
                  try await service.setupLinuxVM()
                } catch {
                  errorMessage = "Failed to setup Linux VM: \(error.localizedDescription)"
                  showingError = true
                }
                isDownloading = false
              }
            } label: {
              if isDownloading && !service.isLinuxReady {
                ProgressView()
                  .scaleEffect(0.7)
                Text("Setting up...")
              } else {
                Text("Setup Linux VM")
              }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isDownloading)
          }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        
        // macOS VM status
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Image(systemName: service.isMacOSReady ? "checkmark.circle.fill" : "circle.dashed")
              .foregroundStyle(service.isMacOSReady ? .green : .secondary)
            Text("macOS VMs")
              .fontWeight(.medium)
          }
          
          if service.isMacOSReady {
            Text("Restore image available")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("For Xcode builds only (~13GB)")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            Button {
              Task {
                isDownloading = true
                do {
                  try await service.downloadMacOSRestoreImage()
                } catch {
                  errorMessage = "Failed to download macOS image: \(error.localizedDescription)"
                  showingError = true
                }
                isDownloading = false
              }
            } label: {
              if isDownloading && !service.isMacOSReady && service.isLinuxReady {
                ProgressView()
                  .scaleEffect(0.7)
                Text("Downloading...")
              } else {
                Text("Download macOS Image")
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDownloading)
          }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
      }
      
      // Show path info
      if service.isVirtualizationAvailable {
        HStack {
          Image(systemName: "folder")
            .foregroundStyle(.secondary)
          Text("VM files stored in: ~/Library/Application Support/KitchenSync/VMs/")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
  
  // MARK: - Test VM Section
  
  @State private var isStartingVM = false
  
  private var testVMSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Test Linux VM")
        .font(.headline)
      
      HStack(spacing: 16) {
        // VM status indicator
        HStack(spacing: 8) {
          Circle()
            .fill(service.isLinuxVMRunning ? .green : .secondary.opacity(0.3))
            .frame(width: 12, height: 12)
          
          Text(service.isLinuxVMRunning ? "Running" : "Stopped")
            .font(.subheadline)
            .foregroundStyle(service.isLinuxVMRunning ? .primary : .secondary)
        }
        
        Spacer()
        
        // Start/Stop button
        if service.isLinuxVMRunning {
          Button {
            Task {
              do {
                try await service.stopLinuxVM()
              } catch {
                errorMessage = "Failed to stop VM: \(error.localizedDescription)"
                showingError = true
              }
            }
          } label: {
            Label("Stop VM", systemImage: "stop.fill")
          }
          .buttonStyle(.bordered)
          .tint(.red)
        } else {
          Button {
            Task {
              isStartingVM = true
              do {
                try await service.startLinuxVM()
              } catch {
                errorMessage = "Failed to start VM: \(error.localizedDescription)"
                showingError = true
              }
              isStartingVM = false
            }
          } label: {
            if isStartingVM {
              ProgressView()
                .scaleEffect(0.7)
              Text("Starting...")
            } else {
              Label("Start VM", systemImage: "play.fill")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isStartingVM)
        }
      }
      .padding()
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
      
      // Info text
      Text("Start a test Linux VM to verify the virtualization setup. The VM boots Alpine Linux in ~3 seconds.")
        .font(.caption)
        .foregroundStyle(.secondary)
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
        ForEach(Array(service.pools.values).sorted(by: { $0.tier.rawValue < $1.tier.rawValue }), id: \.tier) { pool in
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
}

// MARK: - Environment Tier Card

struct EnvironmentTierCard: View {
  let environment: ExecutionEnvironment
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: environment.icon)
          .foregroundStyle(colorForEnvironment)
        Text(environment.displayName)
          .fontWeight(.medium)
      }
      
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Image(systemName: "clock")
            .font(.caption2)
          Text(environment == .host ? "Instant" : "~\(Int(environment.typicalBootTime))s boot")
            .font(.caption)
        }
        .foregroundStyle(.secondary)
        
        if environment.hasANEAccess {
          HStack {
            Image(systemName: "cpu")
              .font(.caption2)
            Text("ANE + GPU")
              .font(.caption)
          }
          .foregroundStyle(.green)
        }
        
        if environment.canRunXcode && environment != .host {
          HStack {
            Image(systemName: "hammer")
              .font(.caption2)
            Text("Xcode")
              .font(.caption)
          }
          .foregroundStyle(.blue)
        }
      }
      
      Text(useCaseText)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
  
  private var colorForEnvironment: Color {
    switch environment {
    case .host: .green
    case .linux: .blue
    case .macos: .purple
    }
  }
  
  private var useCaseText: String {
    switch environment {
    case .host: "Trusted ops, AI inference"
    case .linux: "Git, scripts, compilers"
    case .macos: "Xcode builds, signing"
    }
  }
}

// MARK: - Setup Status Card

struct SetupStatusCard: View {
  let title: String
  let isReady: Bool
  let readyMessage: String
  let notReadyMessage: String
  let icon: String
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
          .foregroundStyle(isReady ? .green : .secondary)
        Text(title)
          .fontWeight(.medium)
      }
      
      Text(isReady ? readyMessage : notReadyMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Pool Card

struct VMPoolCard: View {
  let pool: VMPool
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: iconForTier(pool.tier))
          .foregroundStyle(colorForTier(pool.tier))
        Text(pool.tier.description)
          .fontWeight(.medium)
        Spacer()
        Text(pool.environment.displayName)
          .font(.caption)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(colorForEnvironment(pool.environment).opacity(0.2), in: Capsule())
          .foregroundStyle(colorForEnvironment(pool.environment))
      }
      
      HStack(spacing: 16) {
        VStack(alignment: .leading) {
          Text("Available")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(pool.availableCount)")
            .font(.title3.monospacedDigit())
        }
        
        VStack(alignment: .leading) {
          Text("Busy")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(pool.busyCount)")
            .font(.title3.monospacedDigit())
        }
        
        Spacer()
        
        // Utilization gauge
        Gauge(value: pool.utilizationPercent, in: 0...100) {
          Text("Use")
        } currentValueLabel: {
          Text("\(Int(pool.utilizationPercent))%")
            .font(.caption2)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(pool.utilizationPercent > 80 ? .red : .blue)
        .scaleEffect(0.7)
      }
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
  
  private func iconForTier(_ tier: VMCapabilityTier) -> String {
    switch tier {
    case .readOnlyAnalysis: "eye"
    case .writeAction: "pencil"
    case .networked: "network"
    case .compileFarm: "hammer"
    }
  }
  
  private func colorForTier(_ tier: VMCapabilityTier) -> Color {
    switch tier {
    case .readOnlyAnalysis: .green
    case .writeAction: .orange
    case .networked: .blue
    case .compileFarm: .purple
    }
  }
  
  private func colorForEnvironment(_ env: ExecutionEnvironment) -> Color {
    switch env {
    case .host: .green
    case .linux: .blue
    case .macos: .purple
    }
  }
}

// MARK: - Task Row

struct VMTaskRow: View {
  let task: VMTask
  
  var body: some View {
    HStack {
      Image(systemName: "play.circle.fill")
        .foregroundStyle(.green)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(task.command)
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
        HStack(spacing: 8) {
          Text(task.capability.description)
          Text("•")
          Text(task.environment.displayName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      ProgressView()
        .scaleEffect(0.7)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Result Row

struct VMTaskResultRow: View {
  let result: VMTaskResult
  
  var body: some View {
    HStack {
      Image(systemName: result.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(result.exitCode == 0 ? .green : .red)
      
      VStack(alignment: .leading, spacing: 2) {
        Text("Task \(result.taskId.uuidString.prefix(8))")
          .font(.system(.body, design: .monospaced))
        HStack(spacing: 8) {
          Text(result.environment.displayName)
          if result.bootTime > 0 {
            Text("•")
            Text("Boot: \(String(format: "%.1fs", result.bootTime))")
          }
          Text("•")
          Text("Run: \(String(format: "%.2fs", result.executionTime))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      Text("Exit \(result.exitCode)")
        .font(.caption.monospaced())
        .foregroundStyle(result.exitCode == 0 ? Color.secondary : Color.red)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

#Preview {
  NavigationStack {
    VMIsolationDashboardView()
  }
  .frame(width: 700, height: 900)
}

#endif // os(macOS)
