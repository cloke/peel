//
//  DebugWindowView.swift
//  KitchenSink
//
//  Created by Cory Loken on 1/1/21.
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
      ScrollView {
        LazyVStack {
          ForEach(log.entries) { entry in
            HStack {
              Text(entry.entry)
              Spacer()
            }
          }
        }
      }
      .frame(maxHeight: 400)
    }
    label: {
      HStack {
        Text(log.label)
        Spacer()
        Text("(\(log.entries.count))")
        Button {
          let pasteboard = NSPasteboard.general
          pasteboard.declareTypes([.string], owner: nil)
          pasteboard.setString(log.label, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
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

struct TaskDebugWindow_Previews: PreviewProvider {
  static var previews: some View {
    TaskDebugWindow()
  }
}
