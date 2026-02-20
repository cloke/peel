import Foundation

// MARK: - Copilot Auth (Token Exchange)

/// Handles GitHub Copilot API authentication.
///
/// Auth flow:
/// 1. Read Copilot OAuth token from `~/.config/github-copilot/apps.json`
/// 2. Exchange via `api.github.com/copilot_internal/v2/token` → session token + endpoint
/// 3. Use session token against the returned endpoint (e.g. `api.enterprise.githubcopilot.com`)
///
/// Falls back to GitHub Models API (models.github.ai) for PAT-based auth (GPT only).
public enum CopilotAuth {
  public struct CopilotSession: Sendable {
    public let token: String
    public let endpoint: String
    public let expiresAt: Date

    public init(token: String, endpoint: String, expiresAt: Date) {
      self.token = token
      self.endpoint = endpoint
      self.expiresAt = expiresAt
    }
  }

  /// Endpoint for direct PAT usage (GPT models only)
  public static let modelsAPIEndpoint = "https://models.github.ai/inference/chat/completions"

  /// Full auth flow: find OAuth token → exchange for session → return session.
  /// Falls back to a PAT-based session (GitHub Models API) if no Copilot login found.
  ///
  /// - Parameters:
  ///   - explicitKey: An explicit API key/token to use (overrides auto-detection)
  ///   - onWarning: Optional callback for non-fatal warnings (e.g. PAT fallback notice)
  public static func resolveSession(
    explicitKey: String? = nil,
    onWarning: ((String) -> Void)? = nil
  ) async throws -> CopilotSession {
    // 1. If explicit key is provided, try it as an OAuth token for exchange
    if let key = explicitKey, !key.isEmpty {
      if let session = try? await exchangeToken(key) {
        return session
      }
      // If exchange fails, use it as a PAT (GitHub Models API fallback)
      return CopilotSession(
        token: key,
        endpoint: modelsAPIEndpoint,
        expiresAt: .distantFuture
      )
    }

    // 2. Check ~/.config/github-copilot/apps.json for Copilot OAuth token
    if let oauthToken = readCopilotOAuthToken() {
      return try await exchangeToken(oauthToken)
    }

    // 3. Fall back to gh auth token / env vars → GitHub Models API (GPT only)
    if let pat = resolveGitHubPAT() {
      onWarning?(
        "No Copilot login found — using GitHub Models API (GPT models only).\n"
        + "  Run 'copilot login' for Claude/Gemini model access."
      )
      return CopilotSession(
        token: pat,
        endpoint: modelsAPIEndpoint,
        expiresAt: .distantFuture
      )
    }

    throw CopilotAuthError.noToken
  }

  /// Read the Copilot CLI OAuth token from `~/.config/github-copilot/apps.json`
  public static func readCopilotOAuthToken() -> String? {
    let path = NSString("~/.config/github-copilot/apps.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONDecoder().decode([String: CopilotApp].self, from: data),
          let app = json.values.first
    else { return nil }
    return app.oauth_token
  }

  /// Exchange a Copilot OAuth token for a session token via the internal API.
  public static func exchangeToken(_ oauthToken: String) async throws -> CopilotSession {
    guard let url = URL(string: "https://api.github.com/copilot_internal/v2/token") else {
      throw CopilotAuthError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("token \(oauthToken)", forHTTPHeaderField: "Authorization")
    request.setValue("PeelAgent/0.2.0", forHTTPHeaderField: "editor-version")
    request.setValue("copilot/1.0.0", forHTTPHeaderField: "editor-plugin-version")
    request.setValue("GithubCopilot/1.0.0", forHTTPHeaderField: "user-agent")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw CopilotAuthError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "(empty)"
      throw CopilotAuthError.apiError(statusCode: httpResponse.statusCode, body: body)
    }

    let tokenResponse = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
    let endpoint = tokenResponse.endpoints.api
    let expiresAt = Date(timeIntervalSince1970: TimeInterval(tokenResponse.expires_at))

    return CopilotSession(
      token: tokenResponse.token,
      endpoint: endpoint,
      expiresAt: expiresAt
    )
  }

  /// Get a GitHub PAT from GH_TOKEN, GITHUB_TOKEN, or `gh auth token`
  public static func resolveGitHubPAT() -> String? {
    if let token = ProcessInfo.processInfo.environment["GH_TOKEN"], !token.isEmpty {
      return token
    }
    if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
      return token
    }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh", "auth", "token"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let token = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty
        {
          return token
        }
      }
    } catch {}

    return nil
  }

  /// Check if any Copilot-compatible auth is available (without exchanging)
  public static func isAvailable() -> Bool {
    readCopilotOAuthToken() != nil || resolveGitHubPAT() != nil
  }

  // MARK: - Internal Types

  private struct CopilotApp: Decodable {
    let user: String?
    let oauth_token: String
    let githubAppId: String?
  }

  private struct TokenExchangeResponse: Decodable {
    let token: String
    let endpoints: Endpoints
    let expires_at: Int
    let refresh_in: Int?

    struct Endpoints: Decodable {
      let api: String
    }
  }
}

// MARK: - Legacy Helper (for auto-detection)

/// Convenience for checking if any GitHub/Copilot token is available.
public enum GitHubTokenHelper {
  /// Check if Copilot auth is available (apps.json or gh token)
  public static func resolveToken() -> String? {
    CopilotAuth.readCopilotOAuthToken() ?? CopilotAuth.resolveGitHubPAT()
  }
}

// MARK: - Errors

public enum CopilotAuthError: Error, CustomStringConvertible, Sendable {
  case invalidURL
  case invalidResponse
  case apiError(statusCode: Int, body: String)
  case noToken

  public var description: String {
    switch self {
    case .invalidURL:
      return "Invalid API URL"
    case .invalidResponse:
      return "Invalid response from API"
    case .apiError(let code, let body):
      return "API error (\(code)): \(body)"
    case .noToken:
      return "No GitHub token found. Run 'gh auth login' or set GH_TOKEN/GITHUB_TOKEN"
    }
  }
}
