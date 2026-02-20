import Foundation

// MARK: - Claude Client (Anthropic Messages API)

/// Client for the Anthropic Messages API.
/// Sends requests directly to `api.anthropic.com/v1/messages`.
public final class ClaudeClient: LLMProvider, Sendable {
  private let apiKey: String
  public let model: String
  private let baseURL = "https://api.anthropic.com/v1/messages"

  public init(apiKey: String, model: String) {
    self.apiKey = apiKey
    self.model = model
  }

  /// Send a streaming request, returns an AsyncStream of events
  public func stream(
    messages: [MessagesRequest.Message],
    system: String? = nil,
    tools: [ToolDefinition]? = nil,
    maxTokens: Int = 8192
  ) async throws -> AsyncStream<StreamEvent> {
    let request = MessagesRequest(
      model: model,
      max_tokens: maxTokens,
      system: system,
      messages: messages,
      tools: tools,
      stream: true
    )

    let httpRequest = try buildRequest(body: request)

    let (bytes, response) = try await URLSession.shared.bytes(for: httpRequest)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ClaudeClientError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      var body = ""
      for try await line in bytes.lines {
        body += line
      }
      throw ClaudeClientError.apiError(statusCode: httpResponse.statusCode, body: body)
    }

    return AsyncStream { continuation in
      let task = Task {
        var currentEvent = ""
        var currentData = ""

        for try await line in bytes.lines {
          if line.hasPrefix("event: ") {
            currentEvent = String(line.dropFirst(7))
            currentData = ""
          } else if line.hasPrefix("data: ") {
            currentData += String(line.dropFirst(6))
          } else if line.isEmpty && !currentEvent.isEmpty {
            // End of SSE event — parse it
            if let event = parseSSEEvent(type: currentEvent, data: currentData) {
              continuation.yield(event)
              if case .messageStop = event {
                continuation.finish()
                return
              }
            }
            currentEvent = ""
            currentData = ""
          }
        }
        continuation.finish()
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  // MARK: - Private

  private func buildRequest<T: Encodable>(body: T) throws -> URLRequest {
    guard let url = URL(string: baseURL) else {
      throw ClaudeClientError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(body)
    return request
  }
}

// MARK: - SSE Parsing (Anthropic native format)

private func parseSSEEvent(type: String, data: String) -> StreamEvent? {
  guard let jsonData = data.data(using: .utf8) else { return nil }

  switch type {
  case "message_start":
    guard let wrapper = try? JSONDecoder().decode(MessageStartWrapper.self, from: jsonData) else { return nil }
    return .messageStart(wrapper.message)

  case "content_block_start":
    guard let wrapper = try? JSONDecoder().decode(ContentBlockStartWrapper.self, from: jsonData) else { return nil }
    return .contentBlockStart(index: wrapper.index, wrapper.content_block)

  case "content_block_delta":
    guard let wrapper = try? JSONDecoder().decode(ContentBlockDeltaWrapper.self, from: jsonData) else { return nil }
    return .contentBlockDelta(index: wrapper.index, delta: wrapper.delta)

  case "content_block_stop":
    guard let wrapper = try? JSONDecoder().decode(ContentBlockStopWrapper.self, from: jsonData) else { return nil }
    return .contentBlockStop(index: wrapper.index)

  case "message_delta":
    guard let wrapper = try? JSONDecoder().decode(MessageDeltaWrapper.self, from: jsonData) else { return nil }
    return .messageDelta(stopReason: wrapper.delta.stop_reason, usage: wrapper.usage)

  case "message_stop":
    return .messageStop

  case "ping":
    return .ping

  case "error":
    let errorMsg = String(data: jsonData, encoding: .utf8) ?? "unknown"
    return .error(errorMsg)

  default:
    return nil
  }
}

// MARK: - SSE Wrapper Types

private struct MessageStartWrapper: Decodable {
  let message: MessagesResponse
}

private struct ContentBlockStartWrapper: Decodable {
  let index: Int
  let content_block: ContentBlock
}

private struct ContentBlockDeltaWrapper: Decodable {
  let index: Int
  let delta: StreamDelta
}

private struct ContentBlockStopWrapper: Decodable {
  let index: Int
}

private struct MessageDeltaWrapper: Decodable {
  struct Delta: Decodable {
    let stop_reason: String?
  }
  let delta: Delta
  let usage: StreamUsageDelta?
}

// MARK: - Errors

public enum ClaudeClientError: Error, CustomStringConvertible, Sendable {
  case invalidURL
  case invalidResponse
  case apiError(statusCode: Int, body: String)

  public var description: String {
    switch self {
    case .invalidURL:
      return "Invalid API URL"
    case .invalidResponse:
      return "Invalid response from API"
    case .apiError(let code, let body):
      return "API error (\(code)): \(body)"
    }
  }
}
