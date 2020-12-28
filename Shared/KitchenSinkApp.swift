//
//  KitchenSinkApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Combine

struct DebugLogEntry: Identifiable {
  let id = UUID()
  var entry = ""
}

class DebugLog: ObservableObject, Identifiable {
  var id = UUID()
  let label: String!
  
  @Published var entries = [DebugLogEntry]()
  
  init(label: String) {
    self.label = label
  }
}

class DebugViewModel: ObservableObject {
  @Published var debugLogs = [DebugLog]()
  private var disposables = Set<AnyCancellable>()
  
  static let shared = DebugViewModel()
}

struct TaskDebugDisclosureContentView: View {
  @ObservedObject var log: DebugLog
  
  var body: some View {
    DisclosureGroup {
      ForEach(log.entries) { entry in
        HStack {
        Text(entry.entry)
          Spacer()
        }
      }
    }
    label: {
      HStack {
        Text(log.label)
        Spacer()
        Text("(\(log.entries.count))")
      }
    }
    
  }
}

struct TaskDebugWindow: View {
  @ObservedObject var debugModel: DebugViewModel = .shared
  
  var body: some View {
    ScrollView {
      ForEach(debugModel.debugLogs.reversed()) { log in
        TaskDebugDisclosureContentView(log: log)
      }
    }
  }
}

@main
struct KitchenSinkApp: App {
  @Environment(\.openURL) var openURL
  
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    //    Leaving as example if we want new menus
    //    .commands {
    //      CommandGroup(after: .newItem) {
    //        Button(action: {
    //          if let url = URL(string: "crunchy-kitchen-sink://debug-window") {
    //            openURL(url)
    //          }
    //        }) { Text("Debug Window") }
    //      }
    //    }
    
    WindowGroup("Debug") {
      TaskDebugWindow()
        .padding()
        .frame(minWidth: 600, idealWidth: 600, minHeight: 400, idealHeight: 400)
    }
    
    #if os(macOS)
    Settings {
      SettingsView()
    }
    #endif
  }
}
