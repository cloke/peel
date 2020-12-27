//
//  ApplicationBrewNavigationView.swift
//  KitchenSink (iOS)
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Combine

class SearchResults: ObservableObject {
  let objectWillChange = PassthroughSubject<SearchResults, Never>()
  
  @Published var isSearching = false {
    didSet { objectWillChange.send(self) }
  }
  
  // Store items in a set to prevent duplicates
  var items = Set<String>() {
    didSet {
      // SwiftUI Lists/ForEAch/etc require random access collections
      filtered = Array(items).sorted()
    }
  }
  
  @Published var filtered = [String]() {
    didSet { objectWillChange.send(self) }
  }
  
  @Published var searchText: String = "" {
    didSet { textDidChange.send(searchText) }
  }
  
  private let textDidChange = PassthroughSubject<String, Never>()
  private var cancellables = Set<AnyCancellable>()
  
  init() {
    textDidChange
      .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
      .sink { _ in
        self.search()
      }
      .store(in: &cancellables)
  }
  
  func search() {
    if searchText == "" {
      filtered.removeAll()
      isSearching = false
      return
    }
    
    filtered = items.filter { $0.contains(searchText) }.sorted()
  }
}

extension Brew.SidebarNavigationView {
  class ViewModel: TaskRunnerProtocol {
    @Published var outputStream = [String]()
    
    private var cancellables: Set<AnyCancellable> = []
    
    func installed() {
      outputStream = []
      try? run(.brew, command: Command.BrewInstalled) { [self] in
        switch $0 {
        case .buffer(let string):
          outputStream.append(string)
        case.complete(let data, _):
          print(data)
        }
      }
    }
    
    func available() {
      outputStream = []
      try? run(.brew, command: Command.BrewAvailable) { [self] in
        switch $0 {
        case .buffer(let string):
          outputStream.append(string)
        case.complete(let data, _):
          print(data)
        }
      }
    }
  }
}

extension Brew {
  struct SidebarNavigationView: View {
    @ObservedObject private var results = SearchResults()
    
    var viewModel = ViewModel()
    
    var body: some View {
      VStack {
      HStack {
        Button("Installed") {
          results.items = []
          viewModel.installed()
        }
        Button("Available") {
          results.items = []
          viewModel.available()
        }
      }
      .onReceive(viewModel.$outputStream) { data in
        // TODO: There is no reason to use a stream for the list. 
        DispatchQueue.main.async {
          if data.count > 0 {
            results.items.insert(data.last!)
          }
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
}

struct Brew_SidebarNavigationView_Previews: PreviewProvider {
  static var previews: some View {
    Brew.SidebarNavigationView()
  }
}
