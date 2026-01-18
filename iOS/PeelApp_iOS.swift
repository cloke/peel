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
          OAuthSwift.handle(url: url)
        }
    }
    .modelContainer(sharedModelContainer)
  }
}
