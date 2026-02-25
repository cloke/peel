// VMIsolationMacOSView.swift

import SwiftUI
import AppKit
import Virtualization
import PeelUI

struct VMIsolationMacOSView: View {
  @Environment(VMIsolationService.self) private var service
  @Binding var errorMessage: String?
  @State private var isStartingMacOSVM = false
  @State private var macOSVMWindowController: NSWindowController?

  var body: some View {
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
}

// MARK: - macOS VM Window Controller

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
