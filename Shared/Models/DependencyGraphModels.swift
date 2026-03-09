//
//  DependencyGraphModels.swift
//  Peel
//
//  Data models for dependency graph analysis results.
//

import Foundation

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
