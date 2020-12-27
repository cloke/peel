//
//  Model.swift
//  KitchenSink (iOS)
//
//  Created by Cory Loken on 12/19/20.
//

// The root namespace for all functions related to brew
struct Brew {}

extension Brew {
  struct Info: Codable {
    let description: String?
    let homepage: String?
    let installed: [InfoInstalled]?
    let name: String?
    let versions: AvailableVersion?
    
    enum CodingKeys: String, CodingKey {
      case description = "desc"
      case installed, homepage, name, versions
    }
  }

  struct InfoInstalled: Codable {
    let version: String?
    let used_options: [String]?
    let built_as_bottle: Bool?
    let poured_from_bottle: Bool?
    //  let runtime_dependencies: [[String: Any]]?
    let installed_as_dependency: Bool?
    let installed_on_request: Bool?
  }

  struct AvailableVersion: Codable {
    let stable: String?
    let head: String?
    let bottle: Bool?
  }
}
