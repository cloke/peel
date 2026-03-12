//
//  ManagerOrchestrator.swift
//  Peel
//
//  Orchestrates manager runs: decomposes a high-level prompt into
//  independent sub-tasks via LLM, spawns child runs, and monitors
//  their progress until completion.
//

import Foundation
import Observation
import OSLog

/// Parsed decomposition of a manager prompt into sub-tasks.
struct ManagerDecomposition: Codable, Sendable {
  let tasks: [SubTask]
  let strategy: String?

  struct SubTask: Codable, Sendable {
    let title: String
    let prompt: String
    let templateName: String?
    let priority: Int?
  }

  var isEmpty: Bool { tasks.isEmpty }

  /// Parse the LLM's decomposition output (expects JSON with a `tasks` array).
  static func parse(from output: String) -> ManagerDecomposition? {
    let candidates: [String] = {
      if let fenced = extractCodeFence(from: output) {
        return [fenced, output]
      }
      return [output]
    }()

    for candidate in candidates {
      guard let jsonString = extractFirstJSONObject(in: candidate),
            let data = jsonString.data(using: .utf8) else { continue }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      if let decomp = try? decoder.decode(ManagerDecomposition.self, from: data) {
        return decomp
      }
    }
    return nil
  }

  private static func extractCodeFence(from output: String) -> String? {
    guard let fenceStart = output.range(of: "```") else { return nil }
    let afterStart = output[fenceStart.upperBound...]
    guard let fenceEnd = afterStart.range(of: "```") else { return nil }
    return String(afterStart[..<fenceEnd.lowerBound])
  }

  private static func extractFirstJSONObject(in text: String) -> String? {
    var depth = 0
    var startIndex: String.Index?
    for index in text.indices {
      let char = text[index]
      if char == "{" {
        if depth == 0 { startIndex = index }
        depth += 1
      } else if char == "}" {
        guard depth > 0 else { continue }
        depth -= 1
        if depth == 0, let startIndex {
          return String(text[startIndex...index])
        }
      }
    }
    return nil
  }
}

@MainActor
@Observable
final class ManagerOrchestrator {

  // MARK: - Dependencies

  private let cliService: CLIService
  private let runManager: RunManager

  private let logger = Logger(subsystem: "com.peel", category: "ManagerOrchestrator")

  init(cliService: CLIService, runManager: RunManager) {
    self.cliService = cliService
    self.runManager = runManager
  }

  // MARK: - Decompose + Launch

  /// Decompose a prompt via LLM, create a manager run, spawn children, and return the manager run ID.
  /// This is the "one-shot" entrypoint: prompt → decompose → spawn → monitor.
  func startManagerRun(
    prompt: String,
    projectPath: String,
    baseBranch: String = "HEAD",
    model: CopilotModel = .claudeSonnet45
  ) async throws -> ParallelWorktreeRun {
    // 1. Create the manager run (paused, no execution yet)
    let managerRun = runManager.createManagerRun(
      name: "Manager: \(String(prompt.prefix(60)))",
      prompt: prompt,
      projectPath: projectPath,
      baseBranch: baseBranch
    )
    managerRun.status = .running

    logger.info("Manager run created: \(managerRun.id)")

    // 2. Decompose via LLM
    let decomposition: ManagerDecomposition
    do {
      decomposition = try await decompose(prompt: prompt, projectPath: projectPath, model: model)
    } catch {
      managerRun.status = .failed("Decomposition failed: \(error.localizedDescription)")
      throw error
    }

    guard !decomposition.isEmpty else {
      managerRun.status = .completed
      logger.info("Manager decomposition returned no tasks")
      return managerRun
    }

    logger.info("Decomposed into \(decomposition.tasks.count) sub-tasks")

    // 3. Spawn a child run for each sub-task
    for task in decomposition.tasks {
      runManager.spawnChildRun(
        parentRunId: managerRun.id,
        prompt: task.prompt,
        projectPath: projectPath,
        templateName: task.templateName,
        baseBranch: baseBranch
      )
    }

    // 4. Start monitoring in the background
    Task { @MainActor [weak self] in
      await self?.monitorChildren(of: managerRun)
    }

    return managerRun
  }

  // MARK: - LLM Decomposition

  private func decompose(
    prompt: String,
    projectPath: String,
    model: CopilotModel
  ) async throws -> ManagerDecomposition {
    let systemPrompt = """
      You are a task decomposition agent. Given a high-level goal, break it into \
      independently implementable sub-tasks that can each be executed in a separate \
      git worktree by an AI coding agent.

      Rules:
      - Each task must be self-contained (no dependencies between tasks)
      - Each task should modify different files when possible
      - Keep tasks focused — one logical change per task
      - Include enough context in each task's prompt that an agent can execute it alone

      Respond with ONLY a JSON object (no other text):
      ```json
      {
        "strategy": "Brief description of how you split the work",
        "tasks": [
          {
            "title": "Short title",
            "prompt": "Detailed prompt for the agent including file paths, expected behavior, etc.",
            "priority": 1
          }
        ]
      }
      ```

      The user's goal:
      \(prompt)
      """

    let response = try await cliService.runCopilotSession(
      prompt: systemPrompt,
      model: model,
      role: .planner,
      workingDirectory: projectPath
    )

    guard let decomposition = ManagerDecomposition.parse(from: response.content) else {
      throw ManagerError.decompositionParseFailed(output: String(response.content.prefix(500)))
    }

    return decomposition
  }

  // MARK: - Child Monitoring

  /// Polls child run status and updates the manager run when all children finish.
  private func monitorChildren(of managerRun: ParallelWorktreeRun) async {
    let pollInterval: Duration = .seconds(5)

    while true {
      try? await Task.sleep(for: pollInterval)

      let stats = runManager.childRunStats(of: managerRun.id)

      // No children (shouldn't happen, but guard)
      guard stats.total > 0 else {
        managerRun.status = .completed
        return
      }

      // All done (no running children left)
      let finished = stats.completed + stats.failed + stats.needsReview
      if finished >= stats.total {
        if stats.needsReview > 0 {
          managerRun.status = .awaitingReview
        } else if stats.failed > 0 && stats.completed == 0 {
          managerRun.status = .failed("All \(stats.failed) child runs failed")
        } else {
          managerRun.status = .completed
        }
        logger.info("Manager \(managerRun.id) finished: \(stats.completed) completed, \(stats.failed) failed, \(stats.needsReview) review")
        return
      }

      // Progress is computed from child executions — no manual update needed
    }
  }

  // MARK: - Errors

  enum ManagerError: LocalizedError {
    case decompositionParseFailed(output: String)

    var errorDescription: String? {
      switch self {
      case .decompositionParseFailed(let output):
        return "Failed to parse LLM decomposition. Output: \(output)"
      }
    }
  }
}
