//
//  ApplicationBrewNavigationView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 12/19/20.
//  Updated for error handling on 1/7/26
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
    var isLoading = false
    var errorMessage: String?
    
    func installed() async {
      isLoading = true
      errorMessage = nil
      outputStream = []
      
      do {
        let results = try await Commands.simple(arguments: Command.BrewInstalled)
        outputStream = results
      } catch {
        errorMessage = "Failed to get installed packages: \(error.localizedDescription)"
      }
      
      isLoading = false
    }
    
    func available(term: String) async {
      isLoading = true
      errorMessage = nil
      outputStream = []
      
      var command = Command.BrewAvailable
      command.append(term)
      
      do {
        let results = try await Commands.simple(arguments: command)
        outputStream = results
      } catch {
        errorMessage = "Failed to search packages: \(error.localizedDescription)"
      }
      
      isLoading = false
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
          Task { await viewModel.installed() }
        }
        .disabled(viewModel.isLoading)
        
        Button("Available") {
          results.items = []
          Task { await viewModel.available(term: results.searchText) }
        }
        .disabled(viewModel.isLoading)
        
        if viewModel.isLoading {
          ProgressView()
            .controlSize(.small)
        }
      }
      .onChange(of: viewModel.outputStream) { _, data in
        if let lastItem = data.last {
          results.items.insert(lastItem)
        }
      }
      
      SearchBarView(searchText: $results.searchText, isSearching: $results.isSearching)
        .padding(.all)
      
      if results.filtered.isEmpty && !viewModel.isLoading {
        ContentUnavailableView(
          "No Packages",
          systemImage: "shippingbox",
          description: Text("Click 'Installed' or search for packages")
        )
      } else {
        List(results.filtered, id: \.self) { name in
          NavigationLink(destination: DetailView(name: name)) {
            Text(name)
          }
        }
      }
    }
    .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
      Button("OK") { viewModel.errorMessage = nil }
    } message: {
      Text(viewModel.errorMessage ?? "")
    }
  }
}

#Preview {
  SidebarNavigationView()
}
