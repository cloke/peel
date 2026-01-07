//
//  ApplicationBrewNavigationView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Observation

@MainActor
@Observable
class SearchResults {
  var isSearching = false
  
  // Store items in a set to prevent duplicates
  var items = Set<String>() {
    didSet {
      // SwiftUI Lists/ForEach/etc require random access collections
      filtered = Array(items).sorted()
    }
  }
  
  var filtered = [String]()
  
  var searchText: String = "" {
    didSet {
      searchTask?.cancel()
      searchTask = Task {
        try? await Task.sleep(for: .seconds(0.3))
        guard !Task.isCancelled else { return }
        search()
      }
    }
  }
  
  private var searchTask: Task<Void, Never>?
  
  func search() {
    if searchText.isEmpty {
      filtered.removeAll()
      isSearching = false
      return
    }
    
    filtered = items.filter { $0.contains(searchText) }.sorted()
  }
}

extension SidebarNavigationView {
  @MainActor
  @Observable
  class ViewModel {
    var outputStream = [String]()
    
    func installed() {
      Task {
        outputStream = []
        do {
          let results = try await Commands.simple(arguments: Command.BrewInstalled)
          outputStream = results
        } catch {
          print("Failed to get installed packages: \(error)")
        }
      }
    }
    
    func available(term: String) {
      Task {
        var command = Command.BrewAvailable
        command.append(term)
        outputStream = []
        do {
          let results = try await Commands.simple(arguments: command)
          outputStream = results
        } catch {
          print("Failed to search packages: \(error)")
        }
      }
    }
  }
}

public struct SidebarNavigationView: View {
  @State private var results = SearchResults()
  @State private var viewModel = ViewModel()
  
  public init() {}
  
  public var body: some View {
    VStack {
      HStack {
        Button("Installed") {
          results.items = []
          viewModel.installed()
        }
        Button("Available") {
          results.items = []
          viewModel.available(term: results.searchText)
        }
      }
      .onChange(of: viewModel.outputStream) { _, data in
        if let lastItem = data.last {
          results.items.insert(lastItem)
        }
      }
      SearchBarView(searchText: $results.searchText, isSearching: $results.isSearching)
        .padding(.all)
      List(results.filtered, id: \.self) { name in
        NavigationLink(
          destination:
            DetailView(name: name)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        ) {
          Text(name)
        }
      }
    }
  }
}

struct SidebarNavigationView_Previews: PreviewProvider {
  static var previews: some View {
    SidebarNavigationView()
  }
}
