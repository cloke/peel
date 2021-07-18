//
//  Label.swift
//  Label
//
//  Created by Cory Loken on 7/18/21.
//

import Foundation

extension Github {
  public struct Label: Codable, Identifiable {
    public var id: Int
    public var node_id: String
    public var url: String
    public var name: String
    public var color: String
//    public var default: Bool
    public var description: String
  }
}
