//
//  DependencyGraphD3View.swift
//  Peel
//
//  Interactive D3 force-directed dependency graph rendered in a WKWebView.
//  Shows module-level and submodule-level views of repository dependencies.
//

import SwiftUI
#if os(macOS)
import WebKit
#endif

// MARK: - Graph Data Models

struct GraphNode: Codable {
  let id: String
  let label: String
  let fileCount: Int
  let topLanguage: String?
  let languages: [String: Int]?
  let module: String?
}

struct GraphLink: Codable {
  let source: String
  let target: String
  let weight: Int
  let types: [String: Int]?
}

struct GraphLevel: Codable {
  let nodes: [GraphNode]
  let links: [GraphLink]
}

struct GraphStats: Codable {
  let totalFiles: Int
  let totalDependencies: Int
  let resolvedDependencies: Int
  let inferredDependencies: Int
  let totalModules: Int
}

struct FullGraphData: Codable {
  let repo: String
  let stats: GraphStats
  let moduleGraph: GraphLevel
  let submoduleGraph: GraphLevel
  let fileGraph: GraphLevel?
}

// MARK: - D3 WebView

#if os(macOS)
struct D3GraphWebView: NSViewRepresentable {
  let graphData: FullGraphData

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.preferences.isTextInteractionEnabled = true
    // Allow D3 from CDN
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    guard let htmlURL = Bundle.main.url(forResource: "dependency-graph", withExtension: "html") else {
      // Fallback: load from source directory during development
      let devPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Agents/
        .deletingLastPathComponent() // Applications/
        .deletingLastPathComponent() // Shared/
        .appendingPathComponent("Shared/Resources/dependency-graph.html")

      if FileManager.default.fileExists(atPath: devPath.path) {
        loadHTML(webView: webView, htmlURL: devPath)
      } else {
        webView.loadHTMLString("<h1 style='color:#999;font-family:system-ui;padding:40px'>dependency-graph.html not found in bundle</h1>", baseURL: nil)
      }
      return
    }
    loadHTML(webView: webView, htmlURL: htmlURL)
  }

  private func loadHTML(webView: WKWebView, htmlURL: URL) {
    do {
      var html = try String(contentsOf: htmlURL, encoding: .utf8)

      // Inject graph data before the script runs
      let jsonData = try JSONEncoder().encode(graphData)
      let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

      // Insert data script before closing </head>
      let dataScript = "<script>window.graphData = \(jsonString);</script>"
      html = html.replacingOccurrences(of: "</head>", with: "\(dataScript)\n</head>")

      webView.loadHTMLString(html, baseURL: htmlURL.deletingLastPathComponent())
    } catch {
      webView.loadHTMLString("<h1 style='color:#f66;font-family:system-ui;padding:40px'>Error: \(error.localizedDescription)</h1>", baseURL: nil)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  class Coordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
      if navigationAction.navigationType == .linkActivated,
         let url = navigationAction.request.url,
         (url.scheme == "http" || url.scheme == "https") {
        NSWorkspace.shared.open(url)
        return .cancel
      }
      return .allow
    }
  }
}
#endif

// MARK: - Main View

struct DependencyGraphD3View: View {
  @Bindable var mcpServer: MCPServerService
  @State private var graphData: FullGraphData?
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var selectedRepo: String = ""
  @State private var availableRepos: [(name: String, path: String)] = []

  var body: some View {
    VStack(spacing: 0) {
      // Toolbar
      HStack(spacing: 12) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.title3)
          .foregroundStyle(.purple)
        Text("Dependency Graph")
          .font(.headline)

        Spacer()

        if !availableRepos.isEmpty {
          Picker("Repository", selection: $selectedRepo) {
            Text("Select repo…").tag("")
            ForEach(availableRepos, id: \.path) { repo in
              Text(repo.name).tag(repo.path)
            }
          }
          .frame(width: 200)
          .onChange(of: selectedRepo) { _, newValue in
            if !newValue.isEmpty {
              Task { await buildGraph(repoPath: newValue) }
            }
          }
        }

        if isLoading {
          ProgressView()
            .scaleEffect(0.7)
        }

        Button {
          if !selectedRepo.isEmpty {
            Task { await buildGraph(repoPath: selectedRepo) }
          }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(selectedRepo.isEmpty || isLoading)
        .help("Refresh graph")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.bar)

      Divider()

      // Content
      if let graphData {
        #if os(macOS)
        D3GraphWebView(graphData: graphData)
        #else
        Text("Graph visualization requires macOS")
        #endif
      } else if let errorMessage {
        ContentUnavailableView {
          Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        }
      } else if isLoading {
        VStack(spacing: 12) {
          ProgressView()
          Text("Building dependency graph…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Dependency Graph", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
          Text("Select a repository to visualize its module dependencies.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      await loadRepos()
    }
  }

  // MARK: - Data Loading

  private func loadRepos() async {
    do {
      let repos = try await mcpServer.listRagReposForGraph()
      availableRepos = repos
      // Auto-select first repo if only one
      if availableRepos.count == 1, let first = availableRepos.first {
        selectedRepo = first.path
        await buildGraph(repoPath: first.path)
      }
    } catch {
      errorMessage = "Failed to load repos: \(error.localizedDescription)"
    }
  }

  private func buildGraph(repoPath: String) async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let data = try await mcpServer.buildFullDependencyGraph(repoPath: repoPath)
      graphData = data
    } catch {
      errorMessage = "Failed to build graph: \(error.localizedDescription)"
    }
  }
}
