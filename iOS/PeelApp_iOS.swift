//
//  PeelApp_iOS.swift
//  KitchenSync (iOS)
//
//  Created on 1/18/26.
//

import SwiftUI
import SwiftData
import OAuthSwift

@main
struct PeelApp_iOS: App {
  @Environment(\.openURL) var openURL
  
  private var sharedModelContainer: ModelContainer = {
    let schema = Schema([
      GitHubFavorite.self,
      RecentPullRequest.self,
    ])
    
    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .automatic
    )
    
    do {
      return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }
  }()
  
  var body: some Scene {
    WindowGroup {
      ContentView()
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
          // Handle OAuth callbacks (GitHub auth)
          if url.scheme == "peel" && url.host == "oauth-callback" {
            OAuthSwift.handle(url: url)
          }
          // Handle swarm invite deep links (peel://swarm/join?s=&i=&t=)
          else if url.scheme == "peel" && url.host == "swarm" {
            Task {
              await FirebaseService.shared.handleDeepLink(url)
            }
          }
        }
    }
    .modelContainer(sharedModelContainer)
  }
}
