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
  case macos
  case pools

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .linux: "Linux"
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
  @State private var consoleInput = ""
  @State private var isStartingMacOSVM = false
  @State private var macOSVMWindowController: NSWindowController?
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
      setupStatusSection
      activeTasksSection
      historySection
    case .linux:
      if service.isLinuxReady {
        testVMSection
        consoleSection
      } else {
        setupStatusSection
      }
    case .macos:
      if service.isMacOSReady {
        testMacOSVMSection
      } else {
        setupStatusSection
      }
    case .pools:
      if service.isLinuxReady || service.isMacOSReady {
        poolsSection
      } else {
        setupStatusSection
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
            
            Chip(
              text: "Recommended",
              foreground: .green,
              background: .green.opacity(0.2)
            )
          }
          
          if service.isLinuxReady {
            Text("Alpine Linux kernel + initramfs ready")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Downloads Alpine Linux kernel + initramfs")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            Button {
              Task {
                isDownloading = true
                do {
                  try await service.setupLinuxVM()
                } catch {
                  errorMessage = "Failed to setup Linux VM: \(error.localizedDescription)"
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

      // Dependencies
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: missingDependencies.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(missingDependencies.isEmpty ? .green : .orange)
          Text("Dependencies")
            .fontWeight(.medium)
        }

        if missingDependencies.isEmpty {
          Text("All required tools installed")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Missing: \(missingDependencies.map { $0.tool }.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            Task { await installMissingDependencies() }
          } label: {
            if isInstallingDependencies {
              ProgressView()
                .scaleEffect(0.7)
              Text("Installing...")
            } else {
              Text("Install via Homebrew")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isInstallingDependencies)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
      
      // Show path info
      if service.isVirtualizationAvailable {
        HStack {
          Image(systemName: "folder")
            .foregroundStyle(.secondary)
          Text("VM files stored in: ~/Library/Application Support/Peel/VMs/")
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
            Task { @MainActor in
              do {
                try await service.stopLinuxVM()
              } catch {
                errorMessage = "Failed to stop VM: \(error.localizedDescription)"
              }
            }
          } label: {
            Label("Stop VM", systemImage: "stop.fill")
          }
          .buttonStyle(.bordered)
          .tint(.red)
        } else {
          Button {
            Task { @MainActor in
              isStartingVM = true
              do {
                try await service.startLinuxVM()
              } catch {
                errorMessage = "Failed to start VM: \(error.localizedDescription)"
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
      
      // Info and troubleshooting
      VStack(alignment: .leading, spacing: 8) {
        Text("Start a test Linux VM to verify the virtualization setup.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Text("VM start must run on the main actor. The test kernel uses Alpine Linux for VZLinuxBootLoader compatibility.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        
        HStack(spacing: 12) {
          // Reset button for troubleshooting
          Button {
            Task {
              isDownloading = true
              do {
                try await service.resetLinuxVM()
              } catch {
                errorMessage = "Failed to reset VM: \(error.localizedDescription)"
              }
              isDownloading = false
            }
          } label: {
            Label("Reset Linux VM", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isDownloading || service.isLinuxVMRunning)
          
          // Path info
          Text("Files: ~/Library/Application Support/Peel/VMs/linux/")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        
        // Troubleshooting tip
        if !service.isLinuxVMRunning {
          HStack(spacing: 4) {
            Image(systemName: "lightbulb")
              .foregroundStyle(.yellow)
            Text("Tip: If the VM fails to start, try running the app without the debugger (⌘⌥R in Xcode).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  // MARK: - Console Section

  private var consoleSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Linux Console")
          .font(.headline)
        Spacer()
        Toggle("Console Output", isOn: Binding(
          get: { service.isConsoleOutputEnabled },
          set: { service.setConsoleOutputEnabled($0) }
        ))
        .toggleStyle(.switch)
      }

      Text("Use the serial console to interact with the netboot environment.")
        .font(.caption)
        .foregroundStyle(.secondary)

      ScrollViewReader { proxy in
        ScrollView {
          Text(service.consoleOutput)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .id("console-output")
        }
        .frame(height: 300)
        .padding(8)
        .background(Color.black.opacity(0.9))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.tertiary))
        .onChange(of: service.consoleOutput) { _, _ in
          withAnimation {
            proxy.scrollTo("console-output", anchor: .bottom)
          }
        }
      }

      HStack(spacing: 8) {
        TextField("Send console input", text: $consoleInput)
          .textFieldStyle(.roundedBorder)
        Button("Send") {
          service.sendConsoleInput(consoleInput)
          consoleInput = ""
        }
        .buttonStyle(.bordered)
        .disabled(!service.isLinuxVMRunning)

        Button("Send Enter") {
          service.sendConsoleInput("")
        }
        .buttonStyle(.bordered)
        .disabled(!service.isLinuxVMRunning)

        Button("Clear") {
          service.clearConsoleOutput()
        }
        .buttonStyle(.bordered)
        .disabled(service.consoleOutput.isEmpty)
      }
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - macOS VM Section

  private var testMacOSVMSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Test macOS VM")
        .font(.headline)

      HStack(spacing: 16) {
        HStack(spacing: 8) {
          Circle()
            .fill(service.isMacOSVMRunning ? .green : .secondary.opacity(0.3))
            .frame(width: 12, height: 12)
          Text(service.isMacOSVMRunning ? "Running" : "Stopped")
            .font(.subheadline)
            .foregroundStyle(service.isMacOSVMRunning ? .primary : .secondary)
        }

        Spacer()

        if service.isMacOSVMRunning {
          Button {
            Task { @MainActor in
              do {
                try await service.stopMacOSVM()
              } catch {
                errorMessage = "Failed to stop macOS VM: \(error.localizedDescription)"
              }
            }
          } label: {
            Label("Stop VM", systemImage: "stop.fill")
          }
          .buttonStyle(.bordered)
          .tint(.red)
        } else {
          Button {
            Task { @MainActor in
              isStartingMacOSVM = true
              do {
                try await service.startMacOSVM()
              } catch {
                errorMessage = "Failed to start macOS VM: \(error.localizedDescription)"
              }
              isStartingMacOSVM = false
            }
          } label: {
            if isStartingMacOSVM || service.isMacOSInstalling {
              ProgressView()
                .scaleEffect(0.7)
              Text(service.isMacOSInstalling ? "Installing..." : "Starting...")
            } else {
              Label("Start VM", systemImage: "play.fill")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isStartingMacOSVM || service.isMacOSInstalling)
        }

        if #available(macOS 12.0, *), let vm = service.macOSVirtualMachine, service.isMacOSVMRunning {
          Button {
            showMacOSVMWindow(vm)
          } label: {
            Label("Open VM Viewer", systemImage: "rectangle.on.rectangle")
          }
          .buttonStyle(.bordered)
        }
      }
      .padding()
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 8) {
        Text("Installs macOS into a local VM disk and boots it headlessly.")
          .font(.caption)
          .foregroundStyle(.secondary)

        if !service.isMacOSVMInstalled {
          Button {
            Task { @MainActor in
              do {
                try await service.installMacOSVM()
              } catch {
                errorMessage = "Failed to install macOS VM: \(error.localizedDescription)"
              }
            }
          } label: {
            if service.isMacOSInstalling {
              ProgressView()
                .scaleEffect(0.7)
              Text("Installing...")
            } else {
              Text("Install macOS VM")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(service.isMacOSInstalling)
        } else {
          Text("macOS VM is installed")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  @available(macOS 12.0, *)
  private func showMacOSVMWindow(_ virtualMachine: VZVirtualMachine) {
    if let controller = macOSVMWindowController {
      controller.close()
    }

    let controller = MacOSVMWindowController(virtualMachine: virtualMachine)
    macOSVMWindowController = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
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
}

@available(macOS 12.0, *)
private final class MacOSVMWindowController: NSWindowController {
  private let virtualMachine: VZVirtualMachine

  init(virtualMachine: VZVirtualMachine) {
    self.virtualMachine = virtualMachine

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "macOS VM Viewer"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 640, height: 480)

    let container = VZAspectFitContainerView(
      virtualMachine: virtualMachine,
      displaySize: VMIsolationService.macOSDisplaySize
    )
    window.contentView = container

    super.init(window: window)
  }

  required init?(coder: NSCoder) {
    nil
  }
}

@available(macOS 12.0, *)
private final class VZAspectFitContainerView: NSView {
  private let vmView = VZVirtualMachineView()
  private let displaySize: CGSize
  private var lastBackingScaleFactor: CGFloat = 1

  init(virtualMachine: VZVirtualMachine, displaySize: CGSize) {
    self.displaySize = displaySize
    super.init(frame: .zero)
    wantsLayer = true
    vmView.wantsLayer = true
    vmView.virtualMachine = virtualMachine
    vmView.autoresizingMask = [.width, .height]
    if #available(macOS 14.0, *) {
      vmView.automaticallyReconfiguresDisplay = true
    }
    addSubview(vmView)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateBackingScale()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateBackingScale()
  }

  override func layout() {
    super.layout()
    guard bounds.width > 0, bounds.height > 0 else { return }

    if #available(macOS 14.0, *) {
      vmView.frame = bounds
      return
    }

    let baseSize = resolvedContentSize
    let aspectWidth = baseSize.width
    let aspectHeight = baseSize.height
    let scale = min(bounds.width / aspectWidth, bounds.height / aspectHeight)
    let targetWidth = aspectWidth * scale
    let targetHeight = aspectHeight * scale
    let originX = (bounds.width - targetWidth) / 2
    let originY = (bounds.height - targetHeight) / 2

    if vmView.bounds.size != baseSize {
      vmView.bounds = NSRect(origin: .zero, size: baseSize)
    }
    vmView.frame = NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
  }

  private var resolvedContentSize: CGSize {
    let intrinsic = vmView.intrinsicContentSize
    if intrinsic.width > 0,
       intrinsic.height > 0,
       intrinsic.width != NSView.noIntrinsicMetric,
       intrinsic.height != NSView.noIntrinsicMetric {
      return intrinsic
    }
    let backingScale = resolvedBackingScaleFactor
    return CGSize(width: displaySize.width / backingScale, height: displaySize.height / backingScale)
  }

  private var resolvedBackingScaleFactor: CGFloat {
    if let windowScale = window?.backingScaleFactor {
      return max(windowScale, 1)
    }
    return max(NSScreen.main?.backingScaleFactor ?? 1, 1)
  }

  private func updateBackingScale() {
    let scale = resolvedBackingScaleFactor
    guard abs(scale - lastBackingScaleFactor) > 0.01 else { return }
    lastBackingScaleFactor = scale
    vmView.layer?.contentsScale = scale
    needsLayout = true
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
        Chip(
          text: pool.environment.displayName,
          font: .caption,
          foreground: colorForEnvironment(pool.environment),
          background: colorForEnvironment(pool.environment).opacity(0.2)
        )
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
  .environment(VMIsolationService())
}

