//
//  AppleAIService.swift
//  KitchenSync
//
//  Created on 1/8/26.
//

import Foundation
import FoundationModels

/// Service for interacting with Apple's on-device Foundation Models
@MainActor
@Observable
public final class AppleAIService {
  
  /// Whether Apple AI is available on this device
  public private(set) var isAvailable = false
  
  /// Current session for multi-turn conversations
  private var session: LanguageModelSession?
  
  public init() {
    checkAvailability()
  }
  
  /// Check if Apple AI is available
  public func checkAvailability() {
    // Foundation Models requires Apple Silicon and macOS 26+
    #if arch(arm64)
    isAvailable = true
    #else
    isAvailable = false
    #endif
  }
  
  /// Create a new session with optional instructions
  public func createSession(instructions: String? = nil) {
    session = LanguageModelSession(
      model: .default,
      instructions: instructions
    )
  }
  
  /// Get a response from the on-device model
  /// - Parameters:
  ///   - prompt: The prompt to send
  ///   - instructions: Optional system instructions
  /// - Returns: The model's response
  public func respond(to prompt: String, instructions: String? = nil) async throws -> String {
    // Create session if needed
    if session == nil || instructions != nil {
      createSession(instructions: instructions)
    }
    
    guard let session else {
      throw AppleAIError.sessionNotCreated
    }
    
    let response = try await session.respond(to: prompt)
    return response.content
  }
  
  /// Stream a response from the on-device model
  /// - Parameter prompt: The prompt to send
  /// - Returns: An async stream of response chunks
  public func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      Task {
        guard let session else {
          continuation.finish(throwing: AppleAIError.sessionNotCreated)
          return
        }
        
        let stream = session.streamResponse(to: Prompt(prompt), schema: String.generationSchema)
        do {
          for try await chunk in stream {
            continuation.yield(chunk.content.debugDescription)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }
  
  /// Detect the framework/language of code
  /// - Parameter code: Sample code to analyze
  /// - Returns: Detected framework hint
  public func detectFramework(code: String) async throws -> FrameworkHint {
    let prompt = """
    Analyze this code and determine the primary framework/language.
    Respond with exactly one of: swift, ember, react, python, rust, general
    
    Code:
    \(code.prefix(2000))
    """
    
    let response = try await respond(to: prompt, instructions: "You are a code analyzer. Respond with only the framework name, nothing else.")
    
    // Parse response to FrameworkHint
    let lowercased = response.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    switch lowercased {
    case "swift", "swiftui": return .swift
    case "ember", "ember.js", "emberjs": return .ember
    case "react", "reactjs", "next.js", "nextjs": return .react
    case "python", "django", "flask": return .python
    case "rust": return .rust
    default: return .general
    }
  }
  
  /// Summarize code for context reduction before sending to cloud
  /// - Parameter code: Code to summarize
  /// - Returns: Condensed summary
  public func summarizeCode(_ code: String) async throws -> String {
    let prompt = """
    Provide a brief summary of this code (max 200 words):
    - Main purpose
    - Key classes/functions
    - Important patterns used
    
    Code:
    \(code.prefix(5000))
    """
    
    return try await respond(to: prompt, instructions: "You are a code summarizer. Be concise and technical.")
  }
}

/// Errors for Apple AI Service
public enum AppleAIError: LocalizedError {
  case sessionNotCreated
  case notAvailable
  case streamError(Error)
  
  public var errorDescription: String? {
    switch self {
    case .sessionNotCreated:
      return "Apple AI session not created"
    case .notAvailable:
      return "Apple AI is not available on this device"
    case .streamError(let error):
      return "Stream error: \(error.localizedDescription)"
    }
  }
}


