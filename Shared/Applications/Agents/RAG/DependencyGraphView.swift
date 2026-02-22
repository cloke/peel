//
//  DependencyGraphView.swift
//  KitchenSync
//
//  Created on 1/30/26.
//

import SwiftUI

// MARK: - Dependency Node

struct DependencyNode: Identifiable, Hashable {
  let id: String
  let label: String
  let type: DependencyNodeType
  let isExpanded: Bool
  let depth: Int
  
  enum DependencyNodeType: String, Hashable {
    case file = "file"
    case module = "module"
    case `protocol` = "protocol"
    case `class` = "class"
    
    var icon: String {
      switch self {
      case .file: return "doc.text"
      case .module: return "shippingbox"
      case .protocol: return "p.circle"
      case .class: return "c.circle"
      }
    }
    
    var color: Color {
      switch self {
      case .file: return .blue
      case .module: return .orange
      case .protocol: return .purple
      case .class: return .green
      }
    }
  }
}

// MARK: - Dependency Edge

struct DependencyEdge: Identifiable, Hashable {
  let id: String
  let sourceId: String
  let targetPath: String
  let type: String // import, inherit, conform, include, extend
  
  var typeIcon: String {
    switch type {
    case "import", "require": return "arrow.right.square"
    case "inherit": return "arrow.up.circle"
    case "conform": return "checkmark.seal"
    case "include": return "plus.circle"
    case "extend": return "arrow.up.right.circle"
    default: return "arrow.right"
    }
  }
  
  var typeColor: Color {
    switch type {
    case "import", "require": return .blue
    case "inherit": return .green
    case "conform": return .purple
    case "include": return .orange
    case "extend": return .teal
    default: return .gray
    }
  }
}

// MARK: - Dependency Graph View

struct DependencyGraphView: View {
  @Bindable var mcpServer: MCPServerService
  let repoPath: String
  
  @State private var selectedFile: String = ""
  @State private var dependencies: [DependencyEdge] = []
  @State private var dependents: [DependencyEdge] = []
  @State private var isLoadingDeps: Bool = false
  @State private var isLoadingDependents: Bool = false
  @State private var errorMessage: String?
  @State private var viewMode: ViewMode = .dependencies
  @State private var searchText: String = ""
  @State private var recentFiles: [String] = []
  
  enum ViewMode: String, CaseIterable {
    case dependencies = "Uses"
    case dependents = "Used By"
    case both = "Both"
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // File selector
      HStack(spacing: 8) {
        TextField("File path (e.g., Shared/Services/LocalRAGStore.swift)", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            selectedFile = searchText
            Task { await loadGraph() }
          }
        
        Button("Explore") {
          selectedFile = searchText
          Task { await loadGraph() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(searchText.isEmpty || isLoadingDeps || isLoadingDependents)
      }
      
      // View mode picker
      Picker("View", selection: $viewMode) {
        ForEach(ViewMode.allCases, id: \.self) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: viewMode) { _, _ in
        if !selectedFile.isEmpty {
          Task { await loadGraph() }
        }
      }
      
      // Recent files quick access
      if !recentFiles.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(recentFiles, id: \.self) { file in
              Button {
                searchText = file
                selectedFile = file
                Task { await loadGraph() }
              } label: {
                Text(URL(fileURLWithPath: file).lastPathComponent)
                  .font(.caption2)
                  .lineLimit(1)
              }
              .buttonStyle(.bordered)
              .tint(selectedFile == file ? .accentColor : .secondary)
            }
          }
        }
      }
      
      // Loading indicator
      if isLoadingDeps || isLoadingDependents {
        HStack {
          ProgressView()
            .scaleEffect(0.8)
          Text("Loading graph...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      // Error message
      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
      
      // Graph visualization
      if !selectedFile.isEmpty && !isLoadingDeps && !isLoadingDependents {
        graphContent
      } else if selectedFile.isEmpty {
        ContentUnavailableView {
          Label("Explore Dependencies", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
          Text("Enter a file path to see what it depends on and what depends on it.")
        }
        .frame(minHeight: 150)
      }
    }
  }
  
  @ViewBuilder
  private var graphContent: some View {
    let fileName = URL(fileURLWithPath: selectedFile).lastPathComponent
    
    VStack(alignment: .leading, spacing: 16) {
      // Summary stats
      HStack(spacing: 16) {
        StatBadge(
          label: "Dependencies",
          value: dependencies.count,
          icon: "arrow.right.circle",
          color: .blue
        )
        StatBadge(
          label: "Dependents",
          value: dependents.count,
          icon: "arrow.left.circle",
          color: .green
        )
      }
      
      Divider()
      
      // Tree visualization
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          // Dependencies section (what this file uses)
          if viewMode == .dependencies || viewMode == .both {
            DisclosureGroup(isExpanded: .constant(true)) {
              if dependencies.isEmpty {
                Text("No dependencies found")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.leading, 24)
              } else {
                VStack(alignment: .leading, spacing: 2) {
                  ForEach(dependencyGroups, id: \.type) { group in
                    DependencyGroupRow(group: group, onSelect: selectTarget)
                  }
                }
              }
            } label: {
              HStack {
                Image(systemName: "arrow.right.circle.fill")
                  .foregroundStyle(.blue)
                Text("\(fileName) uses")
                  .fontWeight(.medium)
                Spacer()
                Text("\(dependencies.count)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
          }
          
          // Dependents section (what uses this file)
          if viewMode == .dependents || viewMode == .both {
            DisclosureGroup(isExpanded: .constant(true)) {
              if dependents.isEmpty {
                Text("No dependents found")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.leading, 24)
              } else {
                VStack(alignment: .leading, spacing: 2) {
                  ForEach(dependentGroups, id: \.type) { group in
                    DependencyGroupRow(group: group, onSelect: selectTarget)
                  }
                }
              }
            } label: {
              HStack {
                Image(systemName: "arrow.left.circle.fill")
                  .foregroundStyle(.green)
                Text("Used by")
                  .fontWeight(.medium)
                Spacer()
                Text("\(dependents.count)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      .frame(maxHeight: 400)
    }
  }
  
  // Group dependencies by type for cleaner display
  private var dependencyGroups: [DependencyGroup] {
    Dictionary(grouping: dependencies, by: \.type)
      .map { DependencyGroup(type: $0.key, edges: $0.value) }
      .sorted { $0.type < $1.type }
  }
  
  private var dependentGroups: [DependencyGroup] {
    Dictionary(grouping: dependents, by: \.type)
      .map { DependencyGroup(type: $0.key, edges: $0.value) }
      .sorted { $0.type < $1.type }
  }
  
  private func selectTarget(_ path: String) {
    searchText = path
    selectedFile = path
    Task { await loadGraph() }
  }
  
  private func loadGraph() async {
    guard !selectedFile.isEmpty else { return }
    
    errorMessage = nil
    
    // Add to recent files
    if !recentFiles.contains(selectedFile) {
      recentFiles.insert(selectedFile, at: 0)
      if recentFiles.count > 5 {
        recentFiles.removeLast()
      }
    }
    
    // Load based on view mode
    if viewMode == .dependencies || viewMode == .both {
      await loadDependencies()
    }
    if viewMode == .dependents || viewMode == .both {
      await loadDependents()
    }
  }
  
  private func loadDependencies() async {
    isLoadingDeps = true
    defer { isLoadingDeps = false }
    
    do {
      let result = try await mcpServer.getDependencies(filePath: selectedFile, repoPath: repoPath)
      dependencies = result.map { dep in
        DependencyEdge(
          id: "\(dep.sourceFile)-\(dep.targetPath)-\(dep.dependencyType)",
          sourceId: dep.sourceFile,
          targetPath: dep.targetPath,
          type: dep.dependencyType
        )
      }
    } catch {
      errorMessage = "Failed to load dependencies: \(error.localizedDescription)"
      dependencies = []
    }
  }
  
  private func loadDependents() async {
    isLoadingDependents = true
    defer { isLoadingDependents = false }
    
    do {
      let result = try await mcpServer.getDependents(filePath: selectedFile, repoPath: repoPath)
      dependents = result.map { dep in
        DependencyEdge(
          id: "\(dep.sourceFile)-\(dep.targetPath)-\(dep.dependencyType)",
          sourceId: dep.sourceFile,
          targetPath: dep.targetPath,
          type: dep.dependencyType
        )
      }
    } catch {
      errorMessage = "Failed to load dependents: \(error.localizedDescription)"
      dependents = []
    }
  }
}

// MARK: - Dependency Group

struct DependencyGroup: Identifiable {
  var id: String { type }
  let type: String
  let edges: [DependencyEdge]
  
  var icon: String {
    switch type {
    case "import", "require": return "arrow.right.square"
    case "inherit": return "arrow.up.circle"
    case "conform": return "checkmark.seal"
    case "include": return "plus.circle"
    case "extend": return "arrow.up.right.circle"
    default: return "arrow.right"
    }
  }
  
  var color: Color {
    switch type {
    case "import", "require": return .blue
    case "inherit": return .green
    case "conform": return .purple
    case "include": return .orange
    case "extend": return .teal
    default: return .gray
    }
  }
  
  var label: String {
    switch type {
    case "import": return "Imports"
    case "require": return "Requires"
    case "inherit": return "Inherits"
    case "conform": return "Conforms to"
    case "include": return "Includes"
    case "extend": return "Extends"
    default: return type.capitalized
    }
  }
}

// MARK: - Dependency Group Row

struct DependencyGroupRow: View {
  let group: DependencyGroup
  let onSelect: (String) -> Void
  
  @State private var isExpanded = true
  
  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 1) {
        ForEach(group.edges) { edge in
          Button {
            onSelect(edge.targetPath)
          } label: {
            HStack(spacing: 6) {
              Text("→")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text(edge.targetPath)
                .font(.caption)
                .foregroundStyle(.primary)
              Spacer()
            }
            .padding(.vertical, 2)
            .padding(.leading, 24)
          }
          .buttonStyle(.plain)
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: group.icon)
          .foregroundStyle(group.color)
          .font(.caption)
        Text(group.label)
          .font(.caption)
          .fontWeight(.medium)
        Text("(\(group.edges.count))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 12)
    }
  }
}

// MARK: - Stat Badge

struct StatBadge: View {
  let label: String
  let value: Int
  let icon: String
  let color: Color
  
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .foregroundStyle(color)
      VStack(alignment: .leading, spacing: 0) {
        Text("\(value)")
          .font(.headline)
          .fontWeight(.semibold)
        Text(label)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
}

// Preview disabled - requires MCPServerService instance from app environment
