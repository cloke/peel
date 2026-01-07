//
//  ApplicationBrewDetailView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 12/19/20.
//  Updated for error handling on 1/7/26
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
    var isLoading = false
    var isInstalling = false
    var errorMessage: String?
        
    func details(of _name: String) async {
      isLoading = true
      errorMessage = nil
      
      var cmd = Command.BrewInfo
      cmd.append(_name)
      
      do {
        let infos = try await Commands.executeJSON([Info].self, arguments: cmd)
        guard let decoded = infos.first else {
          errorMessage = "Package not found"
          isLoading = false
          return
        }
        
        self.name = decoded.name ?? ""
        self.desciption = decoded.description ?? ""
        self.homepage = decoded.homepage ?? ""
        self.installed = decoded.installed?.first
        self.versions = decoded.versions
      } catch {
        errorMessage = "Failed to fetch package info: \(error.localizedDescription)"
      }
      
      isLoading = false
    }
    
    func install(target: String, name: String) {
      Task {
        isInstalling = true
        outputStream.removeAll()
        do {
          let args = [target, "/opt/homebrew/bin/brew", "install", name]
          for try await line in await Commands.stream(arguments: args) {
            outputStream.append(line)
          }
          // Refresh details after install
          await details(of: name)
        } catch {
          outputStream.append("Installation failed: \(error.localizedDescription)")
        }
        isInstalling = false
      }
    }
    
    func uninstall(target: String, name: String) {
      Task {
        isInstalling = true
        outputStream.removeAll()
        do {
          let args = [target, "/opt/homebrew/bin/brew", "uninstall", name]
          for try await line in await Commands.stream(arguments: args) {
            outputStream.append(line)
          }
          // Refresh details after uninstall
          await details(of: name)
        } catch {
          outputStream.append("Uninstallation failed: \(error.localizedDescription)")
        }
        isInstalling = false
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
      VStack(spacing: 12) {
        if viewModel.isLoading {
          ProgressView("Loading package info...")
        } else if let error = viewModel.errorMessage {
          ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
          } description: {
            Text(error)
          } actions: {
            Button("Retry") {
              Task { await viewModel.details(of: name) }
            }
          }
        } else {
          // Action buttons
          HStack {
            if viewModel.installed != nil {
              Button("Uninstall") {
                viewModel.uninstall(target: "-x86_64", name: viewModel.name)
              }
              .disabled(viewModel.isInstalling)
            } else if viewModel.versions != nil {
              Button("Install x86_64 (Intel)") {
                viewModel.install(target: "-x86_64", name: viewModel.name)
              }
              .disabled(viewModel.isInstalling)
              
              Button("Install arm (Apple Silicon)") {
                viewModel.install(target: "-arm64", name: viewModel.name)
              }
              .disabled(viewModel.isInstalling)
            }
            
            if viewModel.isInstalling {
              ProgressView()
                .controlSize(.small)
            }
          }
          
          // Package info
          Text(viewModel.name)
            .font(.headline)
          
          Text(viewModel.desciption)
            .foregroundStyle(.secondary)
          
          if !viewModel.homepage.isEmpty, let url = URL(string: viewModel.homepage) {
            Link("Project Homepage", destination: url)
          }
          
          if let installed = viewModel.installed {
            Label("Installed: \(installed.version ?? "unknown")", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else if let versions = viewModel.versions {
            Label("Available: \(versions.stable ?? "unknown")", systemImage: "arrow.down.circle")
              .foregroundStyle(.blue)
          }
        }
      }
      .padding()
      
      Divider()
      
      // Output stream
      if !viewModel.outputStream.isEmpty {
        ScrollView(.vertical) {
          ResultDetailView(resultStream: $viewModel.outputStream)
        }
        .background(Color(nsColor: .textBackgroundColor))
      }
    }
    .task(id: name) {
      await viewModel.details(of: name)
    }
    #else
    Text("This view is not available on iOS")
    #endif
  }
}

#Preview {
  DetailView(name: "wget")
}
