//
//  ApplicationBrewDetailView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Combine
import TaskRunner

extension DetailView {
  class ViewModel: TaskRunnerProtocol, ObservableObject {
    @Published var outputStream = [String]()
    @Published var desciption = ""
    @Published var installed: InfoInstalled? = nil
    @Published var versions: AvailableVersion? = nil
    @Published var homepage = ""
    @Published var name = ""
    
    func details(of _name: String) {
      // This seems messy. Need to think though complex argument strings.
      var cmd = Command.BrewInfo
      cmd.append(_name)
      
      try? run(.brew, command: cmd) { [self] in
        switch $0 {
        case .buffer(_):
          print("Do Nothing")
        case.complete(let data, _):
          guard let decoded = try? JSONDecoder().decode([Info].self, from: data).first else { return }
          DispatchQueue.main.async {
            self.name = decoded.name ?? ""
            self.desciption = decoded.description ?? ""
            self.homepage = decoded.homepage ?? ""
            self.installed = decoded.installed?.first
            self.versions = decoded.versions
          }
        }
      }
    }
    
    func install(target: String, name: String) {
      let cmd = [target, Executable.brew.rawValue, "install", name]
      try? run(.archetecture, command: cmd) { [self] in
        switch $0 {
        case .buffer(let buffer):
          DispatchQueue.main.async {
            self.outputStream.append(buffer)
          }
        case .complete(_, _):
          print("Do nothing")
        }
      }
    }
    
    func uninstall(target: String, name: String) {
      let cmd = [target, Executable.brew.rawValue, "uninstall", name]
      try? run(.archetecture, command: cmd) { [self] in
        switch $0 {
        case .buffer(let buffer):
          DispatchQueue.main.async {
            self.outputStream.append(buffer)
          }
        case .complete(_, _):
          print("Do nothing")
        }
      }
    }
  }
}

struct DetailView: View {
  @ObservedObject private var viewModel = ViewModel()
  var name: String
  var additionalCommand: [String] = []
  
  var body: some View {
    #if os(macOS)
    VSplitView {
      VStack {
        HStack {
          if viewModel.installed != nil {
            Button("Uninstall") {
              viewModel.uninstall(target: "-x86_64", name: viewModel.name)
            }
          } else if viewModel.versions != nil {
            Button("Install x86_64 (Intel)") {
              viewModel.install(target: "-x86_64", name: viewModel.name)
            }
            Button("Install arm (Apple Silicon)") {
              viewModel.install(target: "-arm64", name: viewModel.name)
            }
          }
        }
        Text(viewModel.name)
        Text(viewModel.desciption)
        if !viewModel.homepage.isEmpty {
          Link("Project Homepge", destination: URL(string: viewModel.homepage)!)
        }
        if viewModel.installed != nil {
          Text(viewModel.installed?.version ?? "")
        } else if viewModel.versions != nil {
          Text("Stable: \(viewModel.versions?.stable ?? "unknown")")
        }
      }
      Divider()
      ScrollView(.vertical) {
        ResultDetailView(resultStream: $viewModel.outputStream)
          .frame(idealHeight: 100)
          .background(Color.green)
      }
    }
    .onAppear {
      viewModel.details(of: name)
    }
    #else
    Text("This view is not for iOS")
    #endif
  }
}

struct Brew_DetailView_Previews: PreviewProvider {
  static var previews: some View {
    DetailView(name: "apsx")
  }
}

