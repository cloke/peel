// WorkerMode.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// Headless worker mode for running Peel as a distributed worker.

import Foundation
import os.log

/// Manages headless worker mode for distributed Peel
@MainActor
public final class WorkerMode {
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "WorkerMode")
  
  private var coordinator: SwarmCoordinator?
  private var isRunning = false
  
  public static let shared = WorkerMode()
  
  private init() {}
  
  /// Check if we should run in worker mode based on command line args
  public var shouldRunInWorkerMode: Bool {
    CommandLine.arguments.contains("--worker")
  }
  
  /// Get custom port from command line args
  public var customPort: UInt16? {
    guard let index = CommandLine.arguments.firstIndex(of: "--port"),
          index + 1 < CommandLine.arguments.count,
          let port = UInt16(CommandLine.arguments[index + 1]) else {
      return nil
    }
    return port
  }
  
  /// Start worker mode
  public func start(chainExecutor: ChainExecutorProtocol? = nil) throws {
    guard !isRunning else { return }
    
    let capabilities = WorkerCapabilities.current()
    logger.info("Starting worker mode on \(capabilities.deviceName)")
    
    coordinator = SwarmCoordinator(
      role: .worker,
      capabilities: capabilities,
      chainExecutor: chainExecutor
    )
    coordinator?.delegate = self
    
    let port = customPort ?? 8766
    try coordinator?.start(port: port)
    
    isRunning = true
    
    logger.info("""
      Worker started:
        Device: \(capabilities.deviceName)
        Port: \(port)
        GPU Cores: \(capabilities.gpuCores)
        Neural Engine: \(capabilities.neuralEngineCores)
        Memory: \(capabilities.memoryGB)GB
      
      Waiting for brain connection...
      """)
    
    // Print to stdout for visibility
    print("""
      ┌─────────────────────────────────────────────┐
      │  🍊 Peel Worker Started                     │
      ├─────────────────────────────────────────────┤
      │  Device: \(capabilities.deviceName.padding(toLength: 28, withPad: " ", startingAt: 0)) │
      │  Port: \(String(port).padding(toLength: 30, withPad: " ", startingAt: 0)) │
      │  GPU: \(String(capabilities.gpuCores).padding(toLength: 31, withPad: " ", startingAt: 0)) │
      │  Neural: \(String(capabilities.neuralEngineCores).padding(toLength: 28, withPad: " ", startingAt: 0)) │
      │  RAM: \(String(format: "%d", capabilities.memoryGB).padding(toLength: 31, withPad: " ", startingAt: 0)) │
      ├─────────────────────────────────────────────┤
      │  Status: Waiting for brain...              │
      └─────────────────────────────────────────────┘
      """)
  }
  
  /// Stop worker mode
  public func stop() {
    coordinator?.stop()
    coordinator = nil
    isRunning = false
    logger.info("Worker stopped")
  }
}

// MARK: - SwarmCoordinatorDelegate

extension WorkerMode: SwarmCoordinatorDelegate {
  public func swarmCoordinator(_ coordinator: SwarmCoordinator, didEmit event: SwarmEvent) {
    switch event {
    case .workerConnected(let peer):
      print("✅ Brain connected: \(peer.name)")
      
    case .workerDisconnected(let id):
      print("❌ Brain disconnected: \(id)")
      
    case .taskReceived(let request):
      print("📥 Task received: \(request.id)")
      print("   Prompt: \(request.prompt.prefix(50))...")
      
    case .taskStarted(let id):
      print("⚙️  Task started: \(id)")
      
    case .taskCompleted(let result):
      print("✅ Task completed: \(result.requestId)")
      print("   Duration: \(String(format: "%.2fs", result.duration))")
      print("   Status: \(result.status.rawValue)")
      print("   Outputs: \(result.outputs.count)")
      
    case .taskFailed(let id, let error):
      print("❌ Task failed: \(id)")
      print("   Error: \(error.localizedDescription)")
    }
  }
  
  public func swarmCoordinator(_ coordinator: SwarmCoordinator, shouldExecute request: ChainRequest) -> Bool {
    // Always accept tasks in worker mode
    return true
  }
}
