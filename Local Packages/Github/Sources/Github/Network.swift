//
//  Network.swift
//  Network
//
//  Created by Cory Loken on 7/15/21.
//

import Alamofire
import OAuthSwift
import SwiftUI

enum GithubError: Error {
  case couldNotDecode
}

private struct Config {
  @AppStorage("github-token") var githubToken = ""
}

private let config  = Config()

extension Github {
  /// Allows the application initializers to call back into SwiftUI after OAuth has been completed in the browser
  private static var oauthswift: OAuthSwift?
  
  static var headers: HTTPHeaders {
    return [
      "Authorization": "token \(config.githubToken)",
      "Accept": "application/vnd.github.v3+json",
      "Content-Type": "application/vnd.github.v3+json"
    ]
  }
  
  public static var hasToken: Bool {
    !config.githubToken.isEmpty
  }
  
  /// Returns an array of pull requests from the specified repository
  /// - parameter organization: The github organization or personal repository name
  public static func pullRequests(from repository: Github.Repository) async throws -> [Github.PullRequest] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
    }
    return try await loadMany(url: "https://api.github.com/repos/\(organization)/\(repository.name)/pulls")
  }
  
  public static func loadRepositories(organization: String) async throws -> [Github.Repository] {
    return try await loadMany(url: "https://api.github.com/orgs/\(organization)/repos?per_page=100")
  }
  
  public static func loadOrganizations() async throws -> [Github.User] {
    try await loadMany(url: "https://api.github.com/user/orgs")
  }
  
  public static func loadReviews(organization: String, repository: String, pullNumber: Int) async throws -> [Github.Review] {
    try await loadMany(url: "https://api.github.com/repos/\(organization)/\(repository)/pulls/\(pullNumber)/reviews")
  }
  
  /// Provides the user record of the current authenticated user.
  public static func me() async throws -> Github.User {
    try await load(url: "https://api.github.com/user")
  }
  
  public static func members(from organization: User) async throws -> [Github.User]  {
    if organization.members_url == nil {
      throw AFError.invalidURL(url: "members only exist on organization users")
    }
    /// Git adds /{member} to the url, but we want just the array url.
    let url = "\(organization.members_url![..<organization.members_url!.index(organization.members_url!.endIndex, offsetBy: -9)])"
    return try await loadMany(url: url)
  }
  
  public static func commits(from repository: Repository) async throws -> [Github.Commit] {
    let url = "\(repository.commits_url![..<repository.commits_url!.index(repository.commits_url!.endIndex, offsetBy: -6)])"

    return try await loadMany(url: url)
  }
  
  /// Get the details of a single commit
  static func commitDetail(from commit: Commit) async throws -> Github.CommitDetail {
    try await load(url: commit.url)
  }
  
  static func workflowJobs(from action: Action) async throws -> WorkflowRun {
     try await load(url: action.jobs_url)
  }
  
  static func actions(from repository: Repository) async throws -> Runs {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
    }
    return try await load(url: "https://api.github.com/repos/\(organization)/\(repository.name)/actions/runs")
  }
  
  static func workflows(from repository: Repository) async throws -> [Workflow] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
    }
    let url = "https://api.github.com/repos/\(organization)/\(repository.name)/actions/workflows"

    guard let workflowContainer: Github.WorkflowContainer = try await load(url: url) else {
      throw GithubError.couldNotDecode
    }
    return workflowContainer.workflows
  }
  
  /// Returns an array of Github workflow runs
  /// - Parameters:
  ///   - workflow: Github.Workflow referencing a workflow containing workflow runs
  ///   - repository: repository containing workflows
  /// - Returns: An array of Github actions. [Github.Action]
  static func runs(from workflow: Workflow, repository: Repository) async throws -> [Action] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
    }
    let url = "https://api.github.com/repos/\(organization)/\(repository.name)/actions/workflows/\(workflow.id)/runs"
    guard let workflowContainer: Github.Runs = try await load(url: url) else {
      throw GithubError.couldNotDecode
    }
    
    return workflowContainer.workflow_runs
  }
  
  /// Returns an array of Github issues.
  /// - Parameters:
  ///   - repository: Github.Repository referencing a repository containing issues
  /// - Returns: An array of github issues
  static func issues(from repository: Repository) async throws -> [Issue] {
    let url = "\(repository.issues_url![..<repository.issues_url!.index(repository.issues_url!.endIndex, offsetBy: -9)])"
    return try await loadMany(url: url)
  }
  
  static func createIssue(for repository: Repository, title: String, body: String, owner: String) async throws -> Issue {
    let json = [
      "title": title,
      "body": body,
      "owner": owner
    ]
    
    guard let organization = repository.owner?.login,
          let url = URL(string: "https://api.github.com/repos/\(organization)/\(repository.name)/issues") else {
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
    }
    
    return try await AF.request(url, method: .post, parameters: json, encoder: JSONParameterEncoder.default, headers: headers)
      .serializingDecodable(Issue.self)
      .value
  }
  
  /// Used when the expected response will be a single of codable object.
  private static func load<T: Codable>(url: String) async throws -> T {
    try await AF.request(URL(string: url)!, method: .get, headers: headers)
        .serializingDecodable(T.self)
        .value
  }
  
  /// Used when the expected response will be an array of codable objects.
  /// - Parameter url: url to the github api
  /// - Returns: array of codables
  private static func loadMany<T: Codable>(url: String) async throws -> [T] {
    return try await AF.request(URL(string: url)!, method: .get, headers: headers)
      .serializingDecodable([T].self)
      .value
  }
  
  /// Authorizes with the github api or returns success if token exists. To reset token and access call reauthorize.
  public static func authorize() async throws -> Void {
    if !config.githubToken.isEmpty {
      print("Not empty: \(config.githubToken)")
      return
    }
    
    let oauthswift = OAuth2Swift(
      consumerKey:    "5839b088c4fed070f6e4",
      consumerSecret: "e8cf6fbbb3f25d8671938e3fc375f631c97aa4d4",
      authorizeUrl:   "https://github.com/login/oauth/authorize",
      accessTokenUrl: "https://github.com/login/oauth/access_token",
      responseType:   "code"
    )
    
    self.oauthswift = oauthswift
    oauthswift.authorizeURLHandler = OAuthSwiftOpenURLExternally.sharedInstance
    
    let state = generateState(withLength: 20)
    return await withCheckedContinuation { continuation in
      oauthswift.authorize(
        withCallbackURL: URL(string: "crunchy-kitchen-sink://")!, scope: "user,repo,admin:org,org", state: state) { result in
          switch result {
          case .success(let (credential, _, _)):
            config.githubToken = credential.oauthToken
            print(credential.oauthToken)
            continuation.resume()
          case .failure(let err):
            continuation.resume(throwing: err.underlyingError as! Never)
          }
        }
    }
  }
  
  public static func reauthorize(success: (() -> Void)? = nil, error: (() -> Void)? = nil)  {
    config.githubToken = ""
  }
}
