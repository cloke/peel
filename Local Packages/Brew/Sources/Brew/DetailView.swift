//
//  ApplicationBrewDetailView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Observation
import TaskRunner

#if canImport(AppKit)
import Foundation

/// Brew command executor using modern ProcessExecutor actor.
struct Commands {
  private static let executor = ProcessExecutor()
  private static let brewExecutable = "brew"
  
  /// Execute a brew command and return the result.
  static func execute(arguments: [String]) async throws -> ProcessExecutor.Result {
    try await executor.execute(brewExecutable, arguments: arguments)
  }
  
  /// Execute a brew command that returns JSON and decode it.
  static func executeJSON<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
    try await executor.executeJSON(type, executable: brewExecutable, arguments: arguments)
  }
  
  /// Execute a brew command and return output as lines.
  static func simple(arguments: [String]) async throws -> [String] {
    let result = try await execute(arguments: arguments)
    return result.lines
  }
  
  /// Stream output for long-running commands like install/uninstall.
  static func stream(arguments: [String]) async -> AsyncThrowingStream<String, Error> {
    await executor.stream(brewExecutable, arguments: arguments)
  }
}
#else
struct Commands {
}
#endif


extension DetailView {
  @MainActor
  @Observable
  class ViewModel {
    var outputStream = [String]()
    var desciption = ""
    var installed: InfoInstalled? = nil
    var versions: AvailableVersion? = nil
    var homepage = ""
    var name = ""
        
    func details(of _name: String) async {
      var cmd = Command.BrewInfo
      cmd.append(_name)
      
      do {
        let infos = try await Commands.executeJSON([Info].self, arguments: cmd)
        guard let decoded = infos.first else { return }
        
        // Already on MainActor, direct assignment
        self.name = decoded.name ?? ""
        self.desciption = decoded.description ?? ""
        self.homepage = decoded.homepage ?? ""
        self.installed = decoded.installed?.first
        self.versions = decoded.versions
      } catch {
        // Handle error - could show to user
        print("Failed to fetch brew info: \(error)")
      }
    }
    
    func install(target: String, name: String) {
      Task {
        outputStream.removeAll()
        do {
          // Use arch command for target architecture and stream output
          let args = [target, "/opt/homebrew/bin/brew", "install", name]
          for try await line in await Commands.stream(arguments: args) {
            outputStream.append(line)
          }
        } catch {
          outputStream.append("Installation failed: \(error.localizedDescription)")
        }
      }
    }
    
    func uninstall(target: String, name: String) {
      Task {
        outputStream.removeAll()
        do {
          // Use arch command for target architecture and stream output
          let args = [target, "/opt/homebrew/bin/brew", "uninstall", name]
          for try await line in await Commands.stream(arguments: args) {
            outputStream.append(line)
          }
        } catch {
          outputStream.append("Uninstallation failed: \(error.localizedDescription)")
        }
      }
    }
  }
}

struct DetailView: View {
  @State private var viewModel = ViewModel()
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
    .task(id: name) {
      await viewModel.details(of: name)
    }
    #else
    Text("This view is not for iOS")
    #endif
  }
}

#Preview {
  DetailView(name: "apsx")
}
