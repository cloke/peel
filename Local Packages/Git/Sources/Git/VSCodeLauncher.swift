//
//  VSCodeLauncher.swift
//  Git
//
//  Created by Copilot on 1/17/26.
//

import Foundation


public enum VSCodeLauncherError: LocalizedError {
  case notInstalled

  public var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "VS Code is not installed. Please install it from https://code.visualstudio.com"
    }
  }
}

public enum VSCodeLauncher {
  private static let possiblePaths = [
    "/usr/local/bin/code",
    "/opt/homebrew/bin/code",
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
    "\(NSHomeDirectory())/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  ]

  public static func findExecutable() -> String? {
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }
    return nil
  }

  public static func open(path: String, newWindow: Bool = true) throws {
    guard let vscodePath = findExecutable() else {
      throw VSCodeLauncherError.notInstalled
    }

    var arguments = [String]()
    if newWindow {
      arguments.append("-n")
    }
    arguments.append(path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: vscodePath)
    process.arguments = arguments
    try process.run()
  }
}
