
import Alamofire
import SwiftUI
import OAuthSwift

private struct Config {
  @AppStorage("github-token") var githubToken = ""
}

private let config  = Config()

public struct Github {
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
    loadMany(url: "https://api.github.com/orgs/\(organization)/repos", success: success, error: error)
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
  
  public static func me(success: ((Github.User) -> Void)? = nil,
                        error: ((AFError) -> Void)? = nil) {
    load(url: "https://api.github.com/user", success: success, error: error)
  }
  
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
  
  struct OrganizationRepositoryView: View {
    let organization: Organization
    @State var isExpanded = false
    @State private var repositories = [Repository]()
    
    var body: some View {
      DisclosureGroup(isExpanded: $isExpanded) {
        ForEach(repositories) { repository in
          NavigationLink(destination: Github.PullRequestsView(organization: organization.login, repository: repository.name)) {
            Text(repository.name)
          }
        }
      } label: {
        HStack {
          Text(organization.login)
        }
        .onAppear {
          Github.loadRepositories(organization: organization.login) {
            repositories = $0
          }
        }
      }
    }
  }
  
  public struct RootView: View {
    @State private var organizations = [Organization]()
    @ObservedObject var githubViewModel = ViewModel()
    
    public init() {}
    
    public var body: some View {
      VStack {
        List {
          Text(githubViewModel.me?.name ?? "")
          Button("Login") {
            Github.authorize(success:  {
              Github.me {
                githubViewModel.me = $0
              }
              Github.loadOrganizations() {
                organizations = $0
              }
            })
          }
          
          ForEach(organizations) { organization in
            OrganizationRepositoryView(organization: organization)
          }
        }
        Spacer()
      }
      .environmentObject(githubViewModel)
    }
  }
}

