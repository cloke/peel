//
//  License.swift
//  License
//
//  Created by Cory Loken on 7/14/21.
//

public struct License: Codable {
  public var key: String
  public var name: String
  public var spdx_id: String
  public var url: String?
  public var node_id: String
}
