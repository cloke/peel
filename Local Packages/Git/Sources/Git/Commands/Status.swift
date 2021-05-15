//
//  Status.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-status

extension Commands {
  static func status(on repository: Model.Repository, callback: (([FileDescriptor]) -> ())? = nil) {
    try? Commands.run(.git, command: ["-C", repository.path, "--no-optional-locks", "status", "--porcelain=2"]) {
      switch $0 {
      case .complete(_, let array):
        callback?(array.compactMap { line in
          switch line.first {
          case "1":
            let parts = line.split(separator: " ")
            let path = parts[8..<parts.count]
            return FileDescriptor(
              path: path.joined(separator: " "),
              status: FileStatus(rawValue: parts[1].description) ?? .unknown
            )
          case "2":
            let parts = line.split(separator: " ")
            let path = parts[9..<parts.count]
              
            return FileDescriptor(
              path: path.joined(separator: " ").components(separatedBy: "\t").first ?? "",
              status: FileStatus(rawValue: parts[1].description) ?? .unknown
            )
          case "u": return nil
          case "?":
            let path = line.dropFirst(2)
            return FileDescriptor(
              path: path.description,
              status: FileStatus(rawValue: "?") ?? .unknown
            )
          default: return nil
          }
        })
      default: ()
      }
    }
  }
}
