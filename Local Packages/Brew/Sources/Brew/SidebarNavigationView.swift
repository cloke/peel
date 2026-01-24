//
//  ApplicationBrewNavigationView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 12/19/20.
//  Updated for error handling on 1/7/26
//

import SwiftUI
import Observation
import PeelUI

enum PackageSource: String, CaseIterable, Identifiable {
  case installed = "Installed"
  case available = "Available"
  var id: String { rawValue }
}

@MainActor
@Observable
class SearchResults {
  var isSearching = false
  
  // Store items in a set to prevent duplicates
  var items = Set<String>() {
    didSet {
      // SwiftUI Lists/ForEach/etc require random access collections
      if searchText.isEmpty {
        filtered = Array(items).sorted()
      } else {
        search()
      }
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
      filtered = Array(items).sorted()
      isSearching = false
      return
    }
    
    filtered = items.filter { $0.contains(searchText) }.sorted()
    isSearching = true
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
  @Bindable private var viewModel = ViewModel()
  @AppStorage("brew.source") private var sourceRaw: String = PackageSource.installed.rawValue
  @AppStorage("brew.searchText") private var storedSearchText: String = ""
  @State private var selection: String?
  
  public init() {}
  
  public var body: some View {
    let source = PackageSource(rawValue: sourceRaw) ?? .installed
    NavigationSplitView {
      VStack(spacing: 0) {
        Picker("Source", selection: Binding(
          get: { source },
          set: { sourceRaw = $0.rawValue }
        )) {
          ForEach(PackageSource.allCases) { source in
            Text(source.rawValue).tag(source)
          }
        }
        .pickerStyle(.segmented)
        .padding()
        .disabled(viewModel.isLoading)

        if viewModel.isLoading && results.items.isEmpty {
          ProgressView()
            .controlSize(.small)
            .padding()
        }
        
        if results.filtered.isEmpty && !viewModel.isLoading {
          ContentUnavailableView(
            "No Packages",
            systemImage: "shippingbox",
            description: Text(source == .installed ? "No installed packages found" : "Search for available packages")
          )
        } else {
          List(results.filtered, id: \.self, selection: $selection) { name in
            Text(name)
              .tag(name)
          }
          .listStyle(.sidebar)
        }
      }
    } detail: {
      if let selection {
        DetailView(name: selection)
      } else {
        ContentUnavailableView {
          Label("Select a Package", systemImage: "shippingbox")
        } description: {
          Text("Choose a package from the sidebar to view details")
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .searchable(text: $results.searchText)
    .onChange(of: results.searchText) { _, newValue in
      if storedSearchText != newValue {
        storedSearchText = newValue
      }
    }
    .onChange(of: storedSearchText) { _, newValue in
      if results.searchText != newValue {
        results.searchText = newValue
      }
    }
    .onChange(of: viewModel.outputStream) { _, data in
      results.items = Set(data)
      if !results.items.contains(selection ?? "") {
        selection = nil
      }
    }
    .task(id: sourceRaw) {
      selection = nil
      results.items = []
      if source == .installed {
        await viewModel.installed()
      } else if !results.searchText.isEmpty {
        await viewModel.available(term: results.searchText)
      }
    }
    .task(id: results.searchText) {
      if source == .available {
        try? await Task.sleep(for: .seconds(0.5))
        if !results.searchText.isEmpty {
          selection = nil
          results.items = []
          await viewModel.available(term: results.searchText)
        }
      }
    }
    .errorAlert(message: $viewModel.errorMessage)
  }
}

#Preview {
  SidebarNavigationView()
}
