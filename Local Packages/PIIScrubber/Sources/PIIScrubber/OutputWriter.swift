import Foundation

/// Streaming output writer for writing scrubbed content to a file or stdout.
public final class OutputWriter: @unchecked Sendable {
  private let handle: FileHandle
  private let shouldClose: Bool

  public init(path: String?) throws {
    if let path {
      let url = URL(fileURLWithPath: path)
      let fm = FileManager.default
      fm.createFile(atPath: path, contents: nil)
      handle = try FileHandle(forWritingTo: url)
      shouldClose = true
    } else {
      handle = FileHandle.standardOutput
      shouldClose = false
    }
  }

  public func write(_ string: String) {
    if let data = string.data(using: .utf8) {
      handle.write(data)
    }
  }

  public func close() throws {
    if shouldClose {
      try handle.close()
    }
  }
}
