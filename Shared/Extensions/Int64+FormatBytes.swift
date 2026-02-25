//
//  Int64+FormatBytes.swift
//  Peel
//

import Foundation

extension Int64 {
  var formattedBytes: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: self)
  }
}
