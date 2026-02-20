//
//  VMIntegrationTests.swift
//  Peel
//
//  Integration tests for VM model wiring (no real VM boot).
//

import XCTest
@testable import Peel

#if os(macOS)

@MainActor
final class VMIntegrationTests: XCTestCase {

  func testVMChainModelAndTooling() throws {
    // 1. Create AgentChain configured for VM execution
    let chain = AgentChain(name: "VM Test", workingDirectory: "/tmp/workspace")
    chain.executionEnvironment = .linux
    chain.toolchain = .minimal
    XCTAssertTrue(chain.requiresVM, "Chain should require a VM when executionEnvironment != .host")

    // 2. directoryShares can be mutated
    XCTAssertEqual(chain.directoryShares.count, 0)
    chain.directoryShares.append(.workspace("/tmp/workspace"))
    XCTAssertEqual(chain.directoryShares.count, 1)

    // 3. VMChainExecutor init with a real (non-initialized) VMIsolationService
    let vmService = VMIsolationService()
    let executor = VMChainExecutor(vmService: vmService)
    XCTAssertEqual(executor.state, VMChainExecutor.State.idle)

    // 4. VMToolchain minimal packages
    XCTAssertEqual(VMToolchain.minimal.alpinePackages, [], "Minimal toolchain should not request extra Alpine packages")

    // 5. VMDirectoryShare encoding/decoding roundtrip
    let share = VMDirectoryShare(hostPath: "/tmp/ref", tag: "reference", readOnly: true)
    let encoder = JSONEncoder()
    let data = try encoder.encode(share)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VMDirectoryShare.self, from: data)
    XCTAssertEqual(share, decoded)

    // 6. workspace() factory
    let ws = VMDirectoryShare.workspace("/tmp/ws")
    XCTAssertEqual(ws.tag, "workspace")
    XCTAssertEqual(ws.hostPath, "/tmp/ws")
    XCTAssertFalse(ws.readOnly)
  }
}

#endif
