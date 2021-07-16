//
//  Network.swift
//  Network
//
//  Created by Cory Loken on 7/15/21.
//

import Alamofire
import OAuthSwift
import SwiftUI

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
  
  /// Returns an array of pull requests from the specified repository
  /// - parameter organization: The github organization or personal repository name
  public static func loadPullRequests(organization: String, repository: String,
                                      success: (([Github.PullRequest]) -> Void)? = nil,
                                      error: ((AFError) -> Void)? = nil) {
    loadMany(url: "https://api.github.com/repos/\(organization)/\(repository)/pulls", success: success, error: error)
  }
  
  public static func loadRepositories(organization: String,
                                      success: (([Github.Repository]) -> Void)? = nil,
                                      error: ((AFError) -> Void)? = nil) {
    loadMany(url: "https://api.github.com/orgs/\(organization)/repos?per_page=100", success: success, error: error)
  }
  
  public static func loadOrganizations(success: (([Github.Organization]) -> Void)? = nil,
                                       error: ((AFError) -> Void)? = nil) {
    loadMany(url: "https://api.github.com/user/orgs", success: success, error: error)
  }
  
  public static func loadReviews(organization: String, repository: String, pullNumber: Int,
                                 success: (([Github.Review]) -> Void)? = nil,
                                 error: ((AFError) -> Void)? = nil) {
    loadMany(url: "https://api.github.com/repos/\(organization)/\(repository)/pulls/\(pullNumber)/reviews", success: success, error: error)
  }
  
  /// Provides the user record of the current authenticated user.
  public static func me(success: ((Github.User) -> Void)? = nil,
                        error: ((AFError) -> Void)? = nil) {
    load(url: "https://api.github.com/user", success: success, error: error)
  }
  
  /// Used when the expected response will be a single of codable object.
  private static func load<T: Codable>(url: String,
                                       success: ((T) -> Void)? = nil,
                                       error: ((AFError) -> Void)? = nil) {
    AF.request(URL(string: url)!, method: .get, headers: headers)
      .responseDecodable { (response: DataResponse<T, AFError>) in
        switch response.result {
        case .success(let value):
          print(value)
          success?(value)
        case .failure(let err):
          print(err)
          error?(err)
        }
      }
  }
  
  /// Used when the expected response will be an array of codable objects.
  private static func loadMany<T: Codable>(url: String,
                                           success: (([T]) -> Void)? = nil,
                                           error: ((AFError) -> Void)? = nil) {
    AF.request(URL(string: url)!, method: .get, headers: headers)
      .responseDecodable { (response: DataResponse<[T], AFError>) in
        switch response.result {
        case .success(let value):
          print(value)
          success?(value)
        case .failure(let err):
          print(err)
          error?(err)
        }
      }
  }
  
  /// Authorizes with the github api or returns success if token exists. To reset token and access call reauthorize.
  public static func authorize(success: (() -> Void)? = nil, error: (() -> Void)? = nil)  {
    if !config.githubToken.isEmpty {
      print("Not empty: \(config.githubToken)")
      success?()
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
    let _ = oauthswift.authorize(
      withCallbackURL: URL(string: "crunchy-kitchen-sink://oauth-callback/github")!, scope: "user,repo,admin:org,org", state: state) { result in
        switch result {
        case .success(let (credential, _, _)):
          config.githubToken = credential.oauthToken
          print(credential.oauthToken)
          success?()
        case .failure(let err):
          print(err.description)
          error?()
        }
      }
  }
}
